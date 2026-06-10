import SwiftUI
import SwiftData
import WebKit
import UIKit

enum PresentedSheet: Identifiable {
    case tabs
    case vault
    case siteSettings(String)
    case settings
    case bookmarks
    case history
    case results

    var id: String {
        switch self {
        case .tabs: return "tabs"
        case .vault: return "vault"
        case .siteSettings(let d): return "siteSettings_\(d)"
        case .settings: return "settings"
        case .bookmarks: return "bookmarks"
        case .history: return "history"
        case .results: return "results"
        }
    }
}

/// Lightweight, view-friendly snapshot of one credential in the RCR queue.
struct RCRQueueItem: Identifiable, Hashable {
    let id: String          // credentialID
    let username: String
    let passwordCount: Int
    var isCompleted: Bool
    var isCurrent: Bool
}

@Observable
@MainActor
class BrowserViewModel {
    var tabs: [BrowserTab] = []
    var activeTabIndex: Int = 0
    var urlBarText: String = ""
    var presentedSheet: PresentedSheet?
    var isShowingSaveCredentialAlert: Bool = false
    var toastMessage: String?
    var toastVisible: Bool = false
    var detectedUsername: String = ""
    var detectedPassword: String = ""
    var isAutoSubmitting: Bool = false

    // MARK: - RCR (run-credentials-run) state
    enum RCRStatus {
        case idle, navigating, filling, submitting, waiting, burning, success
    }
    var isRCRRunning: Bool = false
    var rcrStatus: RCRStatus = .idle
    var rcrIndex: Int = 0
    var rcrTotal: Int = 0
    var rcrCurrentDomain: String = ""
    var rcrCurrentUsername: String = ""
    var rcrBurnFlash: Int = 0
    /// True while the runner is performing the configured extra submits
    /// (sure-login). All RCR actions — result observation, advancing,
    /// burning — are paused until this clears.
    var rcrExtraSubmitsInFlight: Bool = false
    /// Queue snapshot built at run start. Mirrors the order the runner walks
    /// so the UI can show "Next 8" and "Completed" without recomputing.
    var rcrQueueUsernames: [String] = []
    var rcrQueuePasswordCounts: [Int] = []
    var rcrCompletedIDs: Set<String> = []
    /// True when the user wants to re-try credentials that previously
    /// returned `failed` (non-success / non-disabled). Off by default —
    /// resume-safe runs skip every terminally-attempted password.
    var retryFailed: Bool = false
    /// Most-recent run completion timestamp — drives the "View Results"
    /// affordance on the queue pill.
    var rcrLastCompletedAt: Date?

    /// The URL captured when the user tapped RCR.
    var rcrTargetURL: URL?
    private var rcrQueueIDs: [String] = []
    private var rcrCurrentPasswords: [String] = []
    private var rcrPasswordIndex: Int = 0
    private var rcrAwaitingNavigation: Bool = false
    private let rcrLastCompletedKey = "rcrLastCompletedID"

    /// True while the user is editing the URL bar — suppresses programmatic
    /// overwrites from navigation events so the user's in-progress text is
    /// never clobbered mid-edit.
    var isURLBarEditing: Bool = false

    // MARK: - Quad Mode
    var isQuadMode: Bool = false
    let quadController: QuadController = QuadController()

    private var modelContext: ModelContext?
    private var siteSettingCache: [String: SiteSetting?] = [:]
    private var excludedDomainCache: Set<String> = []
    private var excludedDomainCacheLoaded: Bool = false
    private var historyDebounceTask: Task<Void, Never>?
    private var lastHistoryURL: String = ""
    private var sureLoginTask: Task<Void, Never>?

    var activeTab: BrowserTab? {
        guard tabs.indices.contains(activeTabIndex) else { return nil }
        return tabs[activeTabIndex]
    }

    /// Default page every new tab opens to.
    static let defaultHomeURL: URL = URL(string: "https://ignitioncasino.ooo/login")!

    func setup(modelContext: ModelContext) {
        self.modelContext = modelContext
        seedVaultIfNeeded(context: modelContext)
        reloadExcludedDomains()
        if tabs.isEmpty {
            addNewTab()
        }
        quadController.setup(modelContext: modelContext, browser: self)
    }

    /// Read-only view of the excluded-domain cache.
    var excludedDomainSet: Set<String> {
        if !excludedDomainCacheLoaded { reloadExcludedDomains() }
        return excludedDomainCache
    }

    func addNewTab(url: URL? = nil) {
        let target = url ?? Self.defaultHomeURL
        let tab = BrowserTab(url: target)
        tabs.append(tab)
        activeTabIndex = tabs.count - 1
        urlBarText = target.absoluteString
    }

    // MARK: - Seed vault

    private func seedVaultIfNeeded(context: ModelContext) {
        let seedKey = "vaultSeedV1Imported"
        if UserDefaults.standard.bool(forKey: seedKey) { return }
        let imported = CredentialImportService.parseMultiPasswordCSV(SeedCredentials.csv)
        guard !imported.isEmpty else {
            UserDefaults.standard.set(true, forKey: seedKey)
            return
        }
        for item in imported {
            let credential = Credential(
                domain: item.domain,
                username: item.username,
                notes: item.notes
            )
            context.insert(credential)
            _ = KeychainService.shared.savePasswords(item.passwords, for: credential.id)
        }
        try? context.save()
        UserDefaults.standard.set(true, forKey: seedKey)
    }

    func closeTab(at index: Int) {
        guard tabs.count > 1 else { return }
        tabs[index].webView?.stopLoading()
        tabs[index].webView = nil
        tabs.remove(at: index)
        if activeTabIndex >= tabs.count {
            activeTabIndex = tabs.count - 1
        }
    }

    func switchToTab(at index: Int) {
        guard tabs.indices.contains(index) else { return }
        let oldTab = activeTab
        oldTab?.captureSnapshot()

        activeTabIndex = index
        let newURL = activeTab?.displayURL ?? ""
        if urlBarText != newURL {
            urlBarText = newURL
        }
        presentedSheet = nil
    }

    func navigateTo(_ input: String) {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let lower = trimmed.lowercased()
        let url: URL?

        if lower.hasPrefix("http://") || lower.hasPrefix("https://") {
            url = URL(string: trimmed) ?? encodedURL(from: trimmed)
        } else if lower.hasPrefix("about:") || lower.hasPrefix("file:") || lower.hasPrefix("data:") {
            url = URL(string: trimmed)
        } else if looksLikeHost(trimmed) {
            url = URL(string: "https://\(trimmed)") ?? encodedURL(from: "https://\(trimmed)")
        } else {
            let query = trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? trimmed
            url = URL(string: "https://www.google.com/search?q=\(query)")
        }

        guard let validURL = url, validURL.scheme != nil else { return }
        urlBarText = validURL.absoluteString

        if isQuadMode {
            quadController.navigateAll(to: validURL)
            return
        }

        guard let tab = activeTab else { return }
        tab.url = validURL
        tab.lastURL = validURL
        tab.webView?.load(URLRequest(url: validURL))
    }

    /// Called when the user toggles between single and quad mode. Carries
    /// the visible URL across so context isn't lost.
    func handleQuadToggle(enteringQuad: Bool) {
        if enteringQuad {
            let url = activeTab?.webView?.url ?? activeTab?.url ?? Self.defaultHomeURL
            quadController.navigateAll(to: url)
            urlBarText = url.absoluteString
        } else {
            let url = quadController.focusedSession.webView?.url
                ?? quadController.focusedSession.url
                ?? Self.defaultHomeURL
            if let tab = activeTab {
                tab.url = url
                tab.lastURL = url
                tab.webView?.load(URLRequest(url: url))
            }
            urlBarText = url.absoluteString
        }
    }

    private func looksLikeHost(_ s: String) -> Bool {
        if s.contains(" ") { return false }
        if s.hasPrefix("[") { return true }
        if s.contains(".") { return true }
        let head = s.split(separator: "/").first.map(String.init) ?? s
        let hostPart = head.split(separator: ":").first.map(String.init) ?? head
        return hostPart.lowercased() == "localhost"
    }

    private func encodedURL(from s: String) -> URL? {
        s.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed)
            .flatMap(URL.init(string:))
    }

    func goBack() { activeTab?.webView?.goBack() }
    func goForward() { activeTab?.webView?.goForward() }
    func reload() { activeTab?.webView?.reload() }

    func updateURLBar() {
        guard !isURLBarEditing else { return }
        let newValue: String
        if isQuadMode {
            newValue = quadController.focusedSession.webView?.url?.absoluteString
                ?? quadController.focusedSession.url?.absoluteString
                ?? ""
        } else {
            newValue = activeTab?.webView?.url?.absoluteString ?? activeTab?.displayURL ?? ""
        }
        guard urlBarText != newValue else { return }
        urlBarText = newValue
    }

    // MARK: - Caches retained for site settings only.

    func invalidateCredentialCache(for domain: String? = nil) {
        // Site-matching is gone, but kept as a no-op so existing call sites
        // (e.g. sheet `onDismiss`) stay valid.
        _ = domain
    }

    func fetchSiteSetting(for domain: String) -> SiteSetting? {
        let lowDomain = domain.lowercased()
        if let cached = siteSettingCache[lowDomain] {
            return cached
        }
        guard let context = modelContext else { return nil }
        let descriptor = FetchDescriptor<SiteSetting>(
            predicate: #Predicate<SiteSetting> { $0.domain == lowDomain }
        )
        let result = try? context.fetch(descriptor).first
        siteSettingCache[lowDomain] = result
        return result
    }

    func invalidateSiteSettingCache(for domain: String) {
        siteSettingCache.removeValue(forKey: domain.lowercased())
    }

    func isDomainExcluded(_ domain: String) -> Bool {
        let canonical = ExcludedDomain.canonicalize(domain)
        guard !canonical.isEmpty else { return false }
        if !excludedDomainCacheLoaded { reloadExcludedDomains() }
        return excludedDomainCache.contains(canonical)
    }

    func reloadExcludedDomains() {
        guard let context = modelContext else {
            excludedDomainCache = []
            excludedDomainCacheLoaded = true
            return
        }
        let descriptor = FetchDescriptor<ExcludedDomain>()
        if let results = try? context.fetch(descriptor) {
            excludedDomainCache = Set(results.map { $0.domain })
        } else {
            excludedDomainCache = []
        }
        excludedDomainCacheLoaded = true
    }

    // MARK: - Auto Login & Sure Login (used by SiteSettings only)

    func performAutoLogin(siteSetting: SiteSetting?) {
        guard let siteSetting, siteSetting.isAutoLoginEnabled else { return }
        isAutoSubmitting = true

        let script = JavaScriptInjectionService.submitFormScript(
            submitSelector: siteSetting.submitButtonSelector
        )

        activeTab?.webView?.evaluateJavaScript(script) { [weak self] _, _ in
            Task { @MainActor in
                guard let self else { return }
                self.installLoginResponseObserverIfEnabled(domain: siteSetting.domain)
                if siteSetting.isSureLoginEnabled {
                    self.startSureLogin(siteSetting: siteSetting)
                } else {
                    self.isAutoSubmitting = false
                }
            }
        }
    }

    static func detectResponseKey(for domain: String) -> String {
        "detectLoginResponse_\(domain.lowercased())"
    }

    func isLoginResponseDetectionEnabled(for domain: String) -> Bool {
        UserDefaults.standard.bool(forKey: Self.detectResponseKey(for: domain))
    }

    func installLoginResponseObserverIfEnabled(domain: String) {
        guard !isRCRRunning else { return }
        guard isLoginResponseDetectionEnabled(for: domain) else { return }
        activeTab?.webView?.evaluateJavaScript(
            JavaScriptInjectionService.loginResponseObserverScript(),
            completionHandler: nil
        )
    }

    func handleLoginResponseMessage(_ payload: [String: Any]) {
        let kind = (payload["kind"] as? String) ?? ""
        switch kind {
        case "success": showToast("Login succeeded")
        case "failed": showToast("Login failed")
        case "blocked": showToast("Account blocked")
        case "timeout": showToast("No login response detected")
        default: break
        }
    }

    private func startSureLogin(siteSetting: SiteSetting) {
        sureLoginTask?.cancel()
        sureLoginTask = Task { [weak self] in
            guard let self else { return }
            let retries = siteSetting.sureLoginRetryCount
            let delay = siteSetting.sureLoginDelaySeconds
            let submitSelector = siteSetting.submitButtonSelector

            for _ in 0..<retries {
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled else { break }

                let script = JavaScriptInjectionService.submitFormScript(submitSelector: submitSelector)
                _ = try? await self.activeTab?.webView?.evaluateJavaScript(script)
            }

            self.isAutoSubmitting = false
        }
    }

    // MARK: - Burn

    func burnCurrentTab() {
        if isQuadMode {
            burnQuadFocused()
            return
        }
        guard let tab = activeTab else { return }
        let lastURL = tab.lastURL ?? tab.url

        let dataStore = tab.webView?.configuration.websiteDataStore ?? WKWebsiteDataStore.default()
        let dataTypes = WKWebsiteDataStore.allWebsiteDataTypes()
        let domain = tab.domain

        Task { @MainActor in
            // Nuke the entire data store for this tab — cookies, cache,
            // local storage, IndexedDB, service workers, session storage.
            await dataStore.removeData(
                ofTypes: dataTypes,
                modifiedSince: Date(timeIntervalSince1970: 0)
            )
            if let context = self.modelContext {
                try? context.delete(
                    model: BrowsingHistoryEntry.self,
                    where: #Predicate<BrowsingHistoryEntry> { $0.domain == domain }
                )
                try? context.save()
            }
            if let url = lastURL {
                tab.webView?.load(URLRequest(url: url))
            } else {
                tab.webView?.reload()
            }
            self.rcrBurnFlash &+= 1
            self.showToast("Session burned & reloaded")
        }
    }

    /// Quad-mode flame: wipes only the focused cell's isolated data store
    /// and reloads the URL it was on.
    func burnQuadFocused() {
        let session = quadController.focusedSession
        let url = session.webView?.url ?? session.url ?? Self.defaultHomeURL
        let index = session.index
        Task { @MainActor in
            await QuadDataStore.burn(index: index)
            session.webView?.load(URLRequest(url: url))
            self.rcrBurnFlash &+= 1
            self.showToast("Cell \(session.id) burned & reloaded")
        }
    }

    // MARK: - Debounced History

    func addHistoryEntry(url: String, title: String) {
        guard url != lastHistoryURL else { return }
        lastHistoryURL = url

        historyDebounceTask?.cancel()
        historyDebounceTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(0.5))
            guard !Task.isCancelled, let self, let context = self.modelContext else { return }
            let domain = CredentialImportService.extractDomain(from: url)
            let entry = BrowsingHistoryEntry(url: url, title: title, domain: domain)
            context.insert(entry)
        }
    }

    func addBookmark() {
        guard let context = modelContext, let tab = activeTab,
              let url = tab.webView?.url?.absoluteString else {
            showToast("Nothing to bookmark")
            return
        }
        let bookmark = Bookmark(url: url, title: tab.title, domain: tab.domain)
        context.insert(bookmark)
        showToast("Bookmark added")
    }

    // MARK: - Save-detection (offer to save after a manual submit)

    func detectAndOfferSave() {
        let offerEnabled = UserDefaults.standard.object(forKey: "offerToSavePasswords") as? Bool ?? true
        guard offerEnabled else { return }
        let domain = activeTab?.domain ?? ""
        guard !isDomainExcluded(domain) else { return }

        let script = JavaScriptInjectionService.extractFilledCredentialsScript()
        activeTab?.webView?.evaluateJavaScript(script) { [weak self] result, _ in
            Task { @MainActor in
                guard let self, let json = result as? String,
                      let data = json.data(using: .utf8),
                      let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let found = dict["found"] as? Bool, found,
                      let username = dict["username"] as? String, !username.isEmpty,
                      let password = dict["password"] as? String, !password.isEmpty else { return }

                guard let context = self.modelContext else { return }
                let descriptor = FetchDescriptor<Credential>(
                    predicate: #Predicate<Credential> { $0.username == username && $0.domain == domain }
                )
                let alreadyExists = (try? context.fetch(descriptor).first) != nil
                if !alreadyExists {
                    self.detectedUsername = username
                    self.detectedPassword = password
                    self.isShowingSaveCredentialAlert = true
                }
            }
        }
    }

    func saveDetectedCredential() {
        guard let context = modelContext, let domain = activeTab?.domain else { return }
        guard !isDomainExcluded(domain) else {
            showToast("Domain is on the exclude list")
            detectedUsername = ""
            detectedPassword = ""
            return
        }
        let credential = Credential(domain: domain, username: detectedUsername)
        context.insert(credential)
        _ = KeychainService.shared.savePassword(detectedPassword, for: credential.id)
        showToast("Credential saved for \(domain)")
        detectedUsername = ""
        detectedPassword = ""
    }

    // MARK: - RCR

    func toggleRCR() {
        if isQuadMode {
            if quadController.anyRCRRunning {
                quadController.stopQuadRCR(reason: "Quad RCR paused")
            } else {
                guard let target = quadController.focusedSession.webView?.url
                    ?? quadController.focusedSession.url else {
                    showToast("Open a login page in any cell first")
                    return
                }
                quadController.startQuadRCR(targetURL: target)
            }
            return
        }
        if isRCRRunning {
            stopRCR(reason: "RCR paused")
        } else {
            startRCR()
        }
    }

    /// Snapshot of upcoming + current + completed credentials for the queue
    /// pill. Returns at most `limit + 1` upcoming items (current + next N).
    func queueSnapshot(upcomingLimit: Int = 8) -> [RCRQueueItem] {
        guard !rcrQueueIDs.isEmpty else { return [] }
        var items: [RCRQueueItem] = []
        let total = rcrQueueIDs.count
        let upper = min(rcrIndex + upcomingLimit + 1, total)
        for i in rcrIndex..<upper {
            let id = rcrQueueIDs[i]
            let username = i < rcrQueueUsernames.count ? rcrQueueUsernames[i] : ""
            let pwCount = i < rcrQueuePasswordCounts.count ? rcrQueuePasswordCounts[i] : 0
            items.append(RCRQueueItem(
                id: id,
                username: username,
                passwordCount: pwCount,
                isCompleted: false,
                isCurrent: i == rcrIndex
            ))
        }
        return items
    }

    /// Done items, in original queue order.
    func completedSnapshot() -> [RCRQueueItem] {
        guard !rcrQueueIDs.isEmpty else { return [] }
        var items: [RCRQueueItem] = []
        for (i, id) in rcrQueueIDs.enumerated() where rcrCompletedIDs.contains(id) {
            let username = i < rcrQueueUsernames.count ? rcrQueueUsernames[i] : ""
            let pwCount = i < rcrQueuePasswordCounts.count ? rcrQueuePasswordCounts[i] : 0
            items.append(RCRQueueItem(
                id: id,
                username: username,
                passwordCount: pwCount,
                isCompleted: true,
                isCurrent: false
            ))
        }
        return items
    }

    func startRCR() {
        guard let context = modelContext else { return }
        if !excludedDomainCacheLoaded { reloadExcludedDomains() }

        guard let target = activeTab?.webView?.url ?? activeTab?.url else {
            showToast("Open a login page first")
            return
        }
        rcrTargetURL = target
        rcrCurrentDomain = target.host(percentEncoded: false) ?? ""

        let descriptor = FetchDescriptor<Credential>(
            sortBy: [
                SortDescriptor(\Credential.domain),
                SortDescriptor(\Credential.username)
            ]
        )
        guard let all = try? context.fetch(descriptor) else { return }
        let queue = all.filter {
            !excludedDomainCache.contains(ExcludedDomain.canonicalize($0.domain))
        }
        guard !queue.isEmpty else {
            showToast("Vault is empty")
            return
        }

        // Build the queue snapshot. Fetch password counts once, off the
        // main thread, so the pill has correct "N pw" badges immediately.
        let credIDs = queue.map(\.id)
        let usernames = queue.map(\.username)
        let counts: [Int] = credIDs.map { id in
            KeychainService.shared.getPasswords(for: id).count
        }

        rcrQueueIDs = credIDs
        rcrQueueUsernames = usernames
        rcrQueuePasswordCounts = counts
        rcrTotal = queue.count
        rcrCompletedIDs = []

        // If the entire vault was previously finished against this same
        // target, treat this press as "start over" — wipe attempt history
        // for the domain so every credential is eligible again.
        let targetDomain = target.host(percentEncoded: false)?.lowercased() ?? ""
        let tracker = AttemptTrackingService.shared
        let allFinished = zip(credIDs, counts).allSatisfy { id, total in
            tracker.credentialIsFinished(
                context: context,
                credentialID: id,
                targetDomain: targetDomain,
                totalPasswords: total
            )
        }
        if allFinished {
            tracker.clearAttempts(context: context, targetDomain: targetDomain)
            UserDefaults.standard.removeObject(forKey: rcrLastCompletedKey)
            rcrIndex = 0
        } else {
            // Resume from saved position (last completed credential).
            let savedID = UserDefaults.standard.string(forKey: rcrLastCompletedKey)
            if let savedID, let idx = rcrQueueIDs.firstIndex(of: savedID) {
                rcrIndex = (idx + 1) % rcrTotal
            } else {
                rcrIndex = 0
            }

            // Skip credentials already finished against this target, or that
            // were ever perma-disabled, or currently temp-disabled.
            while rcrIndex < rcrTotal {
                let id = rcrQueueIDs[rcrIndex]
                let total = rcrQueuePasswordCounts[rcrIndex]
                let finished = tracker.credentialIsFinished(
                    context: context,
                    credentialID: id,
                    targetDomain: targetDomain,
                    totalPasswords: total
                )
                if finished
                    || PermaDisabledStore.shared.isDisabled(credentialID: id)
                    || TempDisabledStore.shared.isDisabled(credentialID: id) {
                    rcrCompletedIDs.insert(id)
                    rcrIndex += 1
                } else {
                    break
                }
            }
        }

        isRCRRunning = true
        rcrStatus = .navigating
        Task { await runCurrentCredential() }
    }

    func stopRCR(reason: String? = nil) {
        isRCRRunning = false
        rcrStatus = .idle
        rcrAwaitingNavigation = false
        rcrTargetURL = nil
        rcrExtraSubmitsInFlight = false
        activeTab?.webView?.evaluateJavaScript(
            JavaScriptInjectionService.rcrUninstallObserverScript(),
            completionHandler: nil
        )
        if let reason { showToast(reason) }
    }

    private func currentRCRCredential() -> Credential? {
        guard rcrIndex < rcrQueueIDs.count, let context = modelContext else { return nil }
        let id = rcrQueueIDs[rcrIndex]
        let descriptor = FetchDescriptor<Credential>(
            predicate: #Predicate<Credential> { $0.id == id }
        )
        return try? context.fetch(descriptor).first
    }

    private func runCurrentCredential() async {
        guard isRCRRunning else { return }
        // Skip any credentials in temp-disabled cooldown OR ever perma-disabled.
        while rcrIndex < rcrQueueIDs.count {
            let id = rcrQueueIDs[rcrIndex]
            if TempDisabledStore.shared.isDisabled(credentialID: id)
                || PermaDisabledStore.shared.isDisabled(credentialID: id) {
                rcrCompletedIDs.insert(id)
                rcrIndex += 1
                rcrPasswordIndex = 0
            } else {
                break
            }
        }
        guard rcrIndex < rcrQueueIDs.count else {
            rcrStatus = .success
            rcrLastCompletedAt = Date()
            UserDefaults.standard.removeObject(forKey: rcrLastCompletedKey)
            showToast("RCR complete (\(rcrTotal)/\(rcrTotal))")
            stopRCR()
            return
        }

        guard let credential = currentRCRCredential() else {
            rcrIndex += 1
            await runCurrentCredential()
            return
        }

        let credID = credential.id
        let allPasswords = await Task.detached {
            KeychainService.shared.getPasswords(for: credID)
        }.value

        guard !allPasswords.isEmpty else {
            persistRCRProgress(completedID: credential.id)
            rcrCompletedIDs.insert(credential.id)
            rcrIndex += 1
            rcrPasswordIndex = 0
            await runCurrentCredential()
            return
        }

        // Filter out already-attempted passwords (resume-safe).
        let targetDomain = rcrTargetURL?.host(percentEncoded: false)?.lowercased() ?? ""
        let tracker = AttemptTrackingService.shared
        let context = modelContext
        let filtered: [String]
        if retryFailed, let context {
            // Only skip success / disabled.
            filtered = allPasswords.filter { pw in
                !tracker.isTerminallyAttempted(
                    context: context,
                    credentialID: credential.id,
                    passwordHash: PasswordFingerprint.hash(pw),
                    targetDomain: targetDomain
                )
            }
        } else if let context {
            // Skip any password with a recorded result (success/disabled/failed).
            let descriptor = FetchDescriptor<AttemptRecord>(
                predicate: #Predicate<AttemptRecord> { rec in
                    rec.credentialID == credID
                        && rec.targetDomain == targetDomain
                        && rec.statusRaw != "pending"
                        && rec.statusRaw != "skipped"
                }
            )
            let attempted = Set(((try? context.fetch(descriptor)) ?? []).map { $0.passwordHash })
            filtered = allPasswords.filter { !attempted.contains(PasswordFingerprint.hash($0)) }
        } else {
            filtered = allPasswords
        }

        guard !filtered.isEmpty else {
            persistRCRProgress(completedID: credential.id)
            rcrCompletedIDs.insert(credential.id)
            rcrIndex += 1
            rcrPasswordIndex = 0
            await runCurrentCredential()
            return
        }

        rcrCurrentPasswords = filtered
        rcrPasswordIndex = 0
        rcrCurrentUsername = credential.username
        if let target = rcrTargetURL {
            rcrCurrentDomain = target.host(percentEncoded: false) ?? credential.domain
        }

        let liveURL = activeTab?.webView?.url ?? activeTab?.url
        if !sameTarget(liveURL, rcrTargetURL), let target = rcrTargetURL {
            rcrStatus = .navigating
            rcrAwaitingNavigation = true
            activeTab?.url = target
            activeTab?.lastURL = target
            activeTab?.webView?.load(URLRequest(url: target))
            return
        }

        await attemptFill()
    }

    private func sameTarget(_ a: URL?, _ b: URL?) -> Bool {
        guard let a, let b else { return false }
        return a.scheme?.lowercased() == b.scheme?.lowercased()
            && a.host(percentEncoded: false)?.lowercased() == b.host(percentEncoded: false)?.lowercased()
            && a.path == b.path
    }

    private func attemptFill() async {
        guard isRCRRunning, !rcrCurrentPasswords.isEmpty else { return }
        guard let credential = currentRCRCredential() else {
            rcrIndex += 1
            await runCurrentCredential()
            return
        }
        let password = rcrCurrentPasswords[rcrPasswordIndex]
        let targetDomain = rcrTargetURL?.host(percentEncoded: false)?.lowercased() ?? credential.domain
        let siteSetting = fetchSiteSetting(for: targetDomain)

        rcrStatus = .filling
        let fillScript = JavaScriptInjectionService.fillCredentialScript(
            username: credential.username,
            password: password,
            usernameSelector: siteSetting?.usernameSelector,
            passwordSelector: siteSetting?.passwordSelector,
            suppressKeyboard: true
        )
        _ = try? await activeTab?.webView?.evaluateJavaScript(fillScript)
        guard isRCRRunning else { return }

        rcrStatus = .submitting
        let submitScript = JavaScriptInjectionService.submitFormScript(
            submitSelector: siteSetting?.submitButtonSelector
        )
        _ = try? await activeTab?.webView?.evaluateJavaScript(submitScript)
        guard isRCRRunning else { return }

        // Optional extra submits (sure-login). All other RCR actions are
        // gated on rcrExtraSubmitsInFlight so observation / advancement /
        // burning don't fire until these finish.
        let extraCount = max(0, UserDefaults.standard.integer(forKey: "rcrExtraSubmits"))
        let rawDelay = UserDefaults.standard.double(forKey: "rcrSubmitDelay")
        let delay = rawDelay > 0 ? rawDelay : 1.5
        if extraCount > 0 {
            rcrExtraSubmitsInFlight = true
            for _ in 0..<extraCount {
                try? await Task.sleep(for: .seconds(delay))
                guard isRCRRunning else { rcrExtraSubmitsInFlight = false; return }
                _ = try? await activeTab?.webView?.evaluateJavaScript(submitScript)
            }
            rcrExtraSubmitsInFlight = false
        }
        guard isRCRRunning else { return }

        credential.lastUsedAt = Date()
        credential.usageCount += 1

        // Pre-record as pending so a crash mid-attempt still leaves a trail.
        if let context = modelContext {
            _ = AttemptTrackingService.shared.recordAttempt(
                context: context,
                credentialID: credential.id,
                username: credential.username,
                password: password,
                passwordIndex: rcrPasswordIndex + 1,
                passwordTotal: rcrCurrentPasswords.count,
                targetDomain: targetDomain,
                sessionTag: "single",
                status: .pending
            )
        }

        rcrStatus = .waiting
        let successSel = siteSetting?.successSelector
        let installScript = JavaScriptInjectionService.rcrInstallObserverScript(successSelector: successSel)
        _ = try? await activeTab?.webView?.evaluateJavaScript(installScript)
        guard isRCRRunning else { return }
    }

    func rcrPageDidFinish() {
        guard isRCRRunning else { return }
        if rcrAwaitingNavigation {
            rcrAwaitingNavigation = false
            Task { await attemptFill() }
            return
        }
        // While extra submits are in flight, do nothing — the observer
        // will be installed by attemptFill() once they complete.
        if rcrExtraSubmitsInFlight { return }
        if rcrStatus == .waiting || rcrStatus == .submitting {
            let successSel = fetchSiteSetting(for: rcrCurrentDomain)?.successSelector
            activeTab?.webView?.evaluateJavaScript(
                JavaScriptInjectionService.rcrInstallObserverScript(successSelector: successSel),
                completionHandler: nil
            )
        }
    }

    func handleRCRStateMessage(_ payload: [String: Any]) {
        guard isRCRRunning, rcrStatus == .waiting else { return }
        if rcrExtraSubmitsInFlight { return }
        let hasPassword = payload["hasPassword"] as? Bool ?? false
        let hasWelcome = payload["hasWelcome"] as? Bool ?? false
        let hasDisabled = payload["hasDisabled"] as? Bool ?? false
        let hasTempDisabled = payload["hasTempDisabled"] as? Bool ?? false
        let hasSuccess = payload["hasSuccess"] as? Bool ?? false
        let isHomepage = payload["isHomepage"] as? Bool ?? false

        guard let credential = currentRCRCredential() else {
            rcrIndex += 1
            Task { await runCurrentCredential() }
            return
        }

        let password = rcrCurrentPasswords[safe: rcrPasswordIndex] ?? ""

        // 1) Success: record + capture, then advance to NEXT credential.
        if hasWelcome || hasSuccess || (isHomepage && !hasPassword) {
            rcrStatus = .success
            persistRCRProgress(completedID: credential.id)
            rcrCompletedIDs.insert(credential.id)
            captureAndRecord(
                credential: credential,
                password: password,
                status: .success
            )
            showToast("Login succeeded — \(credential.username)")
            rcrIndex += 1
            rcrPasswordIndex = 0
            Task { await runCurrentCredential() }
            return
        }

        // 2) Permanent disabled: mark globally, burn, then advance.
        if hasDisabled {
            PermaDisabledStore.shared.markDisabled(credentialID: credential.id)
            captureAndRecord(
                credential: credential,
                password: password,
                status: .disabled
            )
            Task { await burnAndAdvance(completedID: credential.id) }
            return
        }

        // 2b) Temporary disabled: park the credential for 1 hour ONLY if
        // it still has more passwords waiting; otherwise treat as a normal
        // failed attempt.
        if hasTempDisabled {
            captureAndRecord(
                credential: credential,
                password: password,
                status: .tempDisabled
            )
            let hasMore = rcrCurrentPasswords.count > 1
            if hasMore {
                TempDisabledStore.shared.markDisabled(credentialID: credential.id)
                showToast("Temp-disabled — \(credential.username) (1h cooldown)")
                persistRCRProgress(completedID: credential.id)
                rcrCompletedIDs.insert(credential.id)
                rcrIndex += 1
                rcrPasswordIndex = 0
                Task { await runCurrentCredential() }
            } else {
                if rcrPasswordIndex + 1 < rcrCurrentPasswords.count {
                    rcrPasswordIndex += 1
                    Task { await attemptFill() }
                } else {
                    persistRCRProgress(completedID: credential.id)
                    rcrCompletedIDs.insert(credential.id)
                    rcrIndex += 1
                    Task { await runCurrentCredential() }
                }
            }
            return
        }

        // 3) Still on a login form → record as failed, try next password.
        if hasPassword {
            captureAndRecord(
                credential: credential,
                password: password,
                status: .failed
            )
            if rcrPasswordIndex + 1 < rcrCurrentPasswords.count {
                rcrPasswordIndex += 1
                Task { await attemptFill() }
            } else {
                persistRCRProgress(completedID: credential.id)
                rcrCompletedIDs.insert(credential.id)
                rcrIndex += 1
                Task { await runCurrentCredential() }
            }
        }
    }

    private func burnAndAdvance(completedID: String) async {
        rcrStatus = .burning
        rcrBurnFlash &+= 1
        activeTab?.webView?.stopLoading()
        await globalBurn()
        guard isRCRRunning else { return }
        persistRCRProgress(completedID: completedID)
        rcrCompletedIDs.insert(completedID)
        rcrIndex += 1
        rcrPasswordIndex = 0

        if let target = rcrTargetURL {
            rcrStatus = .navigating
            rcrAwaitingNavigation = true
            activeTab?.url = target
            activeTab?.lastURL = target
            activeTab?.webView?.load(URLRequest(url: target))
            return
        }
        await runCurrentCredential()
    }

    private func persistRCRProgress(completedID: String) {
        UserDefaults.standard.set(completedID, forKey: rcrLastCompletedKey)
    }

    private func globalBurn() async {
        let store = WKWebsiteDataStore.default()
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        await store.removeData(ofTypes: types, modifiedSince: Date(timeIntervalSince1970: 0))

        if let context = modelContext {
            try? context.delete(model: BrowsingHistoryEntry.self)
            try? context.save()
        }
        showToast("Burned cookies, cache & history")
    }

    // MARK: - Screenshot capture + record persistence

    private func captureAndRecord(
        credential: Credential,
        password: String,
        status: AttemptRecord.Status
    ) {
        guard let context = modelContext else { return }
        let webView = activeTab?.webView
        let pageURL = webView?.url?.absoluteString
        let pageTitle = webView?.title
        let targetDomain = rcrTargetURL?.host(percentEncoded: false)?.lowercased() ?? credential.domain
        let pwIndex = rcrPasswordIndex + 1
        let pwTotal = rcrCurrentPasswords.count

        // Take the screenshot async so the runner doesn't block on it.
        let credID = credential.id
        let username = credential.username

        if let webView {
            let config = WKSnapshotConfiguration()
            config.snapshotWidth = 600
            webView.takeSnapshot(with: config) { [weak self] image, _ in
                Task { @MainActor in
                    guard let self else { return }
                    let filename = image.flatMap { ScreenshotStorage.save($0) }
                    _ = AttemptTrackingService.shared.recordAttempt(
                        context: context,
                        credentialID: credID,
                        username: username,
                        password: password,
                        passwordIndex: pwIndex,
                        passwordTotal: pwTotal,
                        targetDomain: targetDomain,
                        sessionTag: "single",
                        status: status,
                        resultURL: pageURL,
                        resultPageTitle: pageTitle,
                        screenshotFilename: filename
                    )
                    _ = self // keep the closure capture alive
                }
            }
        } else {
            _ = AttemptTrackingService.shared.recordAttempt(
                context: context,
                credentialID: credID,
                username: username,
                password: password,
                passwordIndex: pwIndex,
                passwordTotal: pwTotal,
                targetDomain: targetDomain,
                sessionTag: "single",
                status: status,
                resultURL: pageURL,
                resultPageTitle: pageTitle,
                screenshotFilename: nil
            )
        }
    }

    /// Master gate for in-app notifications. Off by default; user can
    /// enable from Settings.
    static var notificationsEnabled: Bool {
        UserDefaults.standard.bool(forKey: "inAppNotifications")
    }

    func showToast(_ message: String) {
        guard Self.notificationsEnabled else { return }
        toastMessage = message
        withAnimation(.snappy) { toastVisible = true }
        Task {
            try? await Task.sleep(for: .seconds(2))
            withAnimation(.snappy) { toastVisible = false }
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
