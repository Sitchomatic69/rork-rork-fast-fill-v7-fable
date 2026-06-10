import Foundation
import WebKit
import UIKit

/// Single source of truth for the app's active `BrowsingProfile`.
///
/// Modeled as a Swift actor so persona reads/writes are serialized regardless
/// of the calling context. The persona itself is `Sendable` (immutable
/// `Codable`), so reading it from MainActor UI is cheap.
///
/// The actor also owns the **profile-cycle** orchestration: halting WebKit,
/// awaiting the full async wipe of every `WKWebsiteDataStore` we use,
/// scrubbing `UserDefaults` / `HTTPCookieStorage` / on-disk caches, generating
/// a fresh persona, persisting it, and performing a clean cold-restart.
actor ProfileManager {
    static let shared = ProfileManager()

    // MARK: - State
    private(set) var current: BrowsingProfile

    private enum Keys {
        static let profile = "ffb.profile.v1"
        // Preference keys we wipe on cycle (credentials / vault tables are NOT touched).
        static let nonSensitivePrefixes: [String] = [
            "fp_", "ffb_", "rcr", "tab_", "history_", "vault_view_"
        ]
        // Keys that must never be wiped (e.g. credential seeding flag).
        static let preservedKeys: Set<String> = [
            "vaultSeedV1Imported"
        ]
    }

    private init() {
        if let data = UserDefaults.standard.data(forKey: Keys.profile),
           let p = try? JSONDecoder().decode(BrowsingProfile.self, from: data) {
            self.current = p
        } else {
            var rng = SystemRandomNumberGenerator()
            let p = BrowsingProfileMatrix.generate(using: &rng)
            self.current = p
            if let data = try? JSONEncoder().encode(p) {
                UserDefaults.standard.set(data, forKey: Keys.profile)
            }
        }
    }

    // MARK: - Public reads

    func snapshot() -> BrowsingProfile { current }

    /// Non-actor-isolated cached read for MainActor UI. Returns the
    /// last-persisted profile straight from UserDefaults so call sites
    /// (e.g. `WebViewConfigurationFactory`) never have to await.
    nonisolated static func cachedSnapshot() -> BrowsingProfile {
        if let data = UserDefaults.standard.data(forKey: Keys.profile),
           let p = try? JSONDecoder().decode(BrowsingProfile.self, from: data) {
            return p
        }
        var rng = SystemRandomNumberGenerator()
        return BrowsingProfileMatrix.generate(using: &rng)
    }

    // MARK: - Persona mutation

    func setLocalePreference(_ bcp47: String, timezone: String?) -> BrowsingProfile {
        var rng = SystemRandomNumberGenerator()
        let p = BrowsingProfileMatrix.generate(preferredLocale: bcp47.isEmpty ? nil : bcp47,
                                               preferredTimezone: timezone,
                                               using: &rng)
        persist(p)
        return p
    }

    /// Generates a fresh persona without wiping browsing state. Used by the
    /// Settings fingerprint control; the full privacy-safe path remains
    /// `cycle(...)`, which clears state and cold-restarts.
    func regenerateProfile(preferredLocale: String? = nil, preferredTimezone: String? = nil) -> BrowsingProfile {
        var rng = SystemRandomNumberGenerator()
        let p = BrowsingProfileMatrix.generate(preferredLocale: preferredLocale,
                                               preferredTimezone: preferredTimezone,
                                               using: &rng)
        persist(p)
        return p
    }

    private func persist(_ p: BrowsingProfile) {
        current = p
        if let data = try? JSONEncoder().encode(p) {
            UserDefaults.standard.set(data, forKey: Keys.profile)
        }
    }

    // MARK: - Full cycle

    /// One-button cycle. Halts every web view the caller passes in, awaits a
    /// full async wipe of WebKit state across the default store + every quad
    /// store, scrubs preferences/caches/cookies, generates a new persona,
    /// persists it, and finally — if `coldRestart` is `true` — performs the
    /// suspend + `exit(0)` pattern so the app relaunches under the new
    /// persona with zero residual state.
    func cycle(quadStoreIDs: [UUID], coldRestart: Bool) async {
        await MainActor.run {
            WebViewLifecycleRegistry.shared.stopAllForProfileCycle()
            AlignedURLSession.shared.rebuild()
        }
        await wipeAllWebKitState(quadStoreIDs: quadStoreIDs)
        scrubCookieJarAndCaches()
        scrubPreferences()

        var rng = SystemRandomNumberGenerator()
        let newProfile = BrowsingProfileMatrix.generate(using: &rng)
        persist(newProfile)
        if !coldRestart {
            await MainActor.run { AlignedURLSession.shared.rebuild() }
        }

        if coldRestart {
            await Self.coldRestart()
        }
    }

    /// CRITICAL: awaits the async completion of every WKWebsiteDataStore
    /// removal. Returning before WebKit signals completion leaks state into
    /// the WebContent process and the new persona's first request.
    private func wipeAllWebKitState(quadStoreIDs: [UUID]) async {
        await WebKitWiper.wipe(quadStoreIDs: quadStoreIDs)
    }

    private func scrubCookieJarAndCaches() {
        // HTTPCookieStorage (native URLSession cookies)
        if let jar = HTTPCookieStorage.shared.cookies {
            for c in jar { HTTPCookieStorage.shared.deleteCookie(c) }
        }
        // URLCache (native networking)
        URLCache.shared.removeAllCachedResponses()

        // On-disk caches / tmp
        let fm = FileManager.default
        var dirs: [URL] = []
        if let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask).first {
            dirs.append(caches)
        }
        dirs.append(URL(fileURLWithPath: NSTemporaryDirectory()))
        for dir in dirs {
            if let children = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
                for url in children { try? fm.removeItem(at: url) }
            }
        }
    }

    private func scrubPreferences() {
        let defaults = UserDefaults.standard
        let all = defaults.dictionaryRepresentation()
        for (key, _) in all {
            if Keys.preservedKeys.contains(key) { continue }
            if key == Keys.profile { continue } // re-persisted by persist()
            // Wipe everything else under our control. We're conservative —
            // anything we don't recognize stays put.
            if Keys.nonSensitivePrefixes.contains(where: { key.hasPrefix($0) }) {
                defaults.removeObject(forKey: key)
            }
        }
        defaults.synchronize()
    }

    // MARK: - Cold restart

    /// Suspends the app, waits a tick for the OS to settle the state, then
    /// terminates so the next launch comes up cold. `exit(0)` is acceptable
    /// here because all observable state has already been persisted/scrubbed.
    @MainActor
    private static func coldRestart() async {
        UIApplication.shared.perform(#selector(NSXPCConnection.suspend))
        try? await Task.sleep(for: .milliseconds(400))
        exit(0)
    }
}

/// MainActor-isolated helper that owns the WKWebsiteDataStore wipe. Split out
/// so the actor can `await` a clean async boundary without juggling
/// non-Sendable WebKit types across actor hops.
@MainActor
enum WebKitWiper {
    static func wipe(quadStoreIDs: [UUID]) async {
        let allTypes = WKWebsiteDataStore.allWebsiteDataTypes()
        let epoch = Date(timeIntervalSince1970: 0)

        let defaultStore = WKWebsiteDataStore.default()
        await defaultStore.removeData(ofTypes: allTypes, modifiedSince: epoch)

        for id in quadStoreIDs {
            let store = WKWebsiteDataStore(forIdentifier: id)
            await store.removeData(ofTypes: allTypes, modifiedSince: epoch)
        }
    }
}
