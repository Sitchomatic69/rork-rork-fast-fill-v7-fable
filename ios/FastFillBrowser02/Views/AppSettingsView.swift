import SwiftUI
import WebKit

struct AppSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("autoFillOnPageLoad") private var autoFillOnLoad: Bool = true
    @AppStorage("offerToSavePasswords") private var offerToSave: Bool = true
    @AppStorage("defaultSearchEngine") private var searchEngine: String = "Google"
    @AppStorage("inAppNotifications") private var inAppNotifications: Bool = false
    @AppStorage("rcrExtraSubmits") private var rcrExtraSubmits: Int = 0
    @AppStorage("rcrSubmitDelay") private var rcrSubmitDelay: Double = 1.5
    @State private var isShowingExcludedDomains: Bool = false
    @State private var fingerprintTick: Int = 0
    @State private var showCopiedToast: Bool = false
    @State private var isCyclingProfile: Bool = false
    @State private var showCycleConfirm: Bool = false
    @State private var currentProfile: BrowsingProfile = ProfileManager.cachedSnapshot()

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Theme", selection: Binding(
                    get: { ThemeManager.shared.activeTheme.rawValue },
                    set: { rawValue in
                        if let theme = AppTheme(rawValue: rawValue) {
                            ThemeManager.shared.setTheme(theme)
                        }
                    }
                )) {
                    ForEach(AppTheme.allCases, id: \.self) { theme in
                        HStack(spacing: 8) {
                            Image(systemName: themeIcon(for: theme))
                                .foregroundStyle(theme == .dark ? .indigo : theme == .light ? .orange : .gray)
                            Text(theme.rawValue)
                        }
                        .tag(theme.rawValue)
                    }
                }
            }

            Section("Security") {
                HStack {
                    Image(systemName: "lock.shield.fill")
                        .foregroundStyle(.cyan)
                    Text("Passwords stored in iOS Keychain")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Toggle("Show In-App Notifications", isOn: $inAppNotifications)
            } header: {
                Text("Notifications")
            } footer: {
                Text("When off, the app suppresses every on-screen toast and banner. The RCR queue pill is unaffected.")
            }

            cycleProfileSection

            fingerprintSection

            Section {
                Stepper(value: $rcrExtraSubmits, in: 0...10) {
                    LabeledContent("Extra Submits", value: "\(rcrExtraSubmits)")
                }
                HStack {
                    Text("Delay")
                    Spacer()
                    Text(String(format: "%.1fs", rcrSubmitDelay))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Slider(value: $rcrSubmitDelay, in: 0.5...5.0, step: 0.1)
            } header: {
                Text("RCR Sure-Login")
            } footer: {
                Text("After the initial submit, RCR fires the configured extra submits with this delay. All other actions pause until they finish.")
            }

            Section("Auto Fill") {
                Toggle("Auto-fill on Page Load", isOn: $autoFillOnLoad)
                Toggle("Offer to Save New Passwords", isOn: $offerToSave)

                Button {
                    isShowingExcludedDomains = true
                } label: {
                    HStack {
                        Label("Excluded Domains", systemImage: "nosign")
                            .foregroundStyle(.primary)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
            }

            Section("Browser") {
                Picker("Search Engine", selection: $searchEngine) {
                    Text("Google").tag("Google")
                    Text("DuckDuckGo").tag("DuckDuckGo")
                    Text("Bing").tag("Bing")
                }
            }

            Section("About") {
                LabeledContent("Version", value: "1.0.0")
                LabeledContent("Build", value: "1")

                HStack {
                    Image(systemName: "bolt.shield.fill")
                        .foregroundStyle(.linearGradient(
                            colors: [.cyan, .blue],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ))
                    VStack(alignment: .leading) {
                        Text("Fast Fill Browser")
                            .font(.headline)
                        Text("The smartest, most forgiving login browser")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Done") { dismiss() }
            }
        }
        .sheet(isPresented: $isShowingExcludedDomains) {
            NavigationStack { ExcludedDomainsView() }
        }
        .overlay(alignment: .top) {
            if showCopiedToast {
                Text("Copied")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.thinMaterial, in: .capsule)
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
    }

    // MARK: - Cycle Browsing Profile

    @ViewBuilder
    private var cycleProfileSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                        .foregroundStyle(.linearGradient(
                            colors: [.cyan, .blue],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ))
                    Text("Cycle Browsing Profile")
                        .font(.headline)
                    Spacer()
                }
                Text("Generates a brand-new iOS device persona (UA, screen, GPU, audio, locale, timezone) and wipes every byte of WebKit state — cookies, cache, local storage, IndexedDB, service workers — across the default and all Quad sessions. The app cold-restarts under the new identity. Saved credentials and RCR settings are preserved.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button {
                    showCycleConfirm = true
                } label: {
                    HStack {
                        if isCyclingProfile {
                            ProgressView()
                                .progressViewStyle(.circular)
                                .tint(.white)
                        } else {
                            Image(systemName: "arrow.triangle.2.circlepath")
                        }
                        Text(isCyclingProfile ? "Cycling…" : "Cycle Profile & Cold-Restart")
                            .fontWeight(.semibold)
                        Spacer()
                    }
                    .foregroundStyle(.white)
                    .padding(.vertical, 12)
                    .padding(.horizontal, 14)
                    .background(
                        LinearGradient(
                            colors: [.cyan, .blue],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        in: .rect(cornerRadius: 12)
                    )
                }
                .buttonStyle(.plain)
                .disabled(isCyclingProfile)
            }
            .padding(.vertical, 4)
        } header: {
            Text("Privacy")
        } footer: {
            Text("Use after each session against a single target so the new persona shares no observable state with the previous one.")
        }
        .confirmationDialog(
            "Cycle browsing profile?",
            isPresented: $showCycleConfirm,
            titleVisibility: .visible
        ) {
            Button("Cycle & Cold-Restart", role: .destructive) {
                runCycle()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This wipes all WebKit state and restarts the app. Saved credentials and RCR settings are kept.")
        }
    }

    private func runCycle() {
        isCyclingProfile = true
        UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
        Task {
            await ProfileManager.shared.cycle(
                quadStoreIDs: QuadDataStore.identifiers,
                coldRestart: true
            )
            await MainActor.run {
                isCyclingProfile = false
                currentProfile = ProfileManager.cachedSnapshot()
                fingerprintTick &+= 1
            }
        }
    }

    // MARK: - Fingerprint section (reads directly from BrowsingProfile)

    @ViewBuilder
    private var fingerprintSection: some View {
        Section {
            // Summary card
            Button {
                UIPasteboard.general.string = currentProfile.userAgent
                withAnimation(.snappy) { showCopiedToast = true }
                Task {
                    try? await Task.sleep(for: .seconds(1.1))
                    withAnimation(.snappy) { showCopiedToast = false }
                }
            } label: {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Image(systemName: "fingerprint")
                            .foregroundStyle(.linearGradient(
                                colors: [.cyan, .blue],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ))
                        Text("Current Fingerprint")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Image(systemName: "doc.on.doc")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    Text(currentProfile.userAgent)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                    HStack(spacing: 12) {
                        Label(profileLocaleDisplay, systemImage: "globe")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Label(currentProfile.timezone, systemImage: "clock")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .id(fingerprintTick)
            }
            .buttonStyle(.plain)

            // Locale picker — reads/writes through ProfileManager
            Picker(selection: Binding(
                get: { currentProfile.locale },
                set: { newValue in
                    updateProfile(locale: newValue, timezone: currentProfile.timezone)
                }
            )) {
                ForEach(BrowsingProfileMatrix.locales, id: \.bcp47) { loc in
                    Text(displayName(for: loc.bcp47)).tag(loc.bcp47)
                }
            } label: {
                Label("Locale", systemImage: "globe")
            }

            // Timezone picker — updates ProfileManager
            Picker(selection: Binding(
                get: { currentProfile.timezone },
                set: { newValue in
                    updateProfile(locale: currentProfile.locale, timezone: newValue)
                }
            )) {
                ForEach(allTimezones, id: \.self) { tz in
                    Text(tz).tag(tz)
                }
            } label: {
                Label("Timezone", systemImage: "clock")
            }

            Button {
                updateProfile(locale: currentProfile.locale, timezone: currentProfile.timezone, forceNewDevice: true)
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            } label: {
                HStack {
                    Image(systemName: "dice.fill")
                    Text("Regenerate Active Profile")
                        .fontWeight(.semibold)
                    Spacer()
                }
                .foregroundStyle(.white)
                .padding(.vertical, 10)
                .padding(.horizontal, 12)
                .background(
                    LinearGradient(
                        colors: [.cyan, .blue],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    in: .rect(cornerRadius: 10)
                )
            }
            .buttonStyle(.plain)
            .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))

            LabeledContent("Device", value: currentProfile.deviceModelKey)
            LabeledContent("Cores", value: "\(currentProfile.hardwareConcurrency)")
            LabeledContent("Screen", value: "\(currentProfile.screenWidth)×\(currentProfile.screenHeight) @\(String(format: "%.0fx", currentProfile.devicePixelRatio))")
        } header: {
            Text("Fingerprint")
        } footer: {
            Text("Every single and 2×2 browser window now uses this one coherent profile. Reload open pages after changing it, or use Cycle Browsing Profile for the strongest state reset.")
        }
    }

    // MARK: - Helpers

    private var profileLocaleDisplay: String {
        let locale = currentProfile.locale
        return displayName(for: locale)
    }

    private func displayName(for bcp47: String) -> String {
        BrowsingProfileMatrix.locales.first(where: { $0.bcp47 == bcp47 })?.acceptLanguage
            .components(separatedBy: ",").first?.components(separatedBy: ";").first ?? bcp47
    }

    private var allTimezones: [String] {
        var unique = Set<String>()
        for loc in BrowsingProfileMatrix.locales {
            for tz in loc.timezones { unique.insert(tz) }
        }
        return Array(unique).sorted()
    }

    private func themeIcon(for theme: AppTheme) -> String {
        switch theme {
        case .system: return "circle.lefthalf.filled"
        case .light: return "sun.max.fill"
        case .dark: return "moon.fill"
        }
    }

    private func updateProfile(locale: String, timezone: String, forceNewDevice: Bool = false) {
        Task {
            let profile: BrowsingProfile
            if forceNewDevice {
                profile = await ProfileManager.shared.regenerateProfile(
                    preferredLocale: locale,
                    preferredTimezone: timezone
                )
            } else {
                profile = await ProfileManager.shared.setLocalePreference(locale, timezone: timezone)
            }
            await MainActor.run {
                currentProfile = profile
                AlignedURLSession.shared.rebuild()
                fingerprintTick &+= 1
                refreshAllWebViewUAs()
            }
        }
    }

    /// After a profile change, update customUserAgent on every live web view
    /// so existing tabs don't lag behind the new persona's UA.
    private func refreshAllWebViewUAs() {
        let newUA = WebViewConfigurationFactory.currentUA
        for case let webView as WKWebView in WebViewLifecycleRegistry.shared.allWebViews() {
            webView.customUserAgent = newUA
        }
    }
}
