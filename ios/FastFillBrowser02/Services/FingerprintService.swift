import Foundation

/// Owns the per-session randomized "fingerprint" — User-Agent generation
/// for single and quad modes. Locale and timezone are now managed exclusively
/// by `ProfileManager` → `BrowsingProfile` so there is one source of truth.
@Observable
@MainActor
final class FingerprintService {
    static let shared = FingerprintService()

    // MARK: - State

    /// User-Agent for single-mode browsing. Re-rolled on app launch and on
    /// every manual Regenerate tap.
    private(set) var singleUserAgent: String

    /// Persistent per-cell User-Agents (S1…S4). Survive launches.
    private(set) var cellUserAgents: [String]

    private enum Keys {
        static let cellUAPrefix = "fp_cell_ua_"
    }

    private init() {
        self.singleUserAgent = Self.generateRandomUserAgent()
        var cells: [String] = []
        for i in 0..<4 {
            let key = Keys.cellUAPrefix + String(i)
            if let saved = UserDefaults.standard.string(forKey: key), !saved.isEmpty {
                cells.append(saved)
            } else {
                let ua = Self.generateRandomUserAgent()
                UserDefaults.standard.set(ua, forKey: key)
                cells.append(ua)
            }
        }
        self.cellUserAgents = cells
    }

    // MARK: - Accessors

    /// Returns the User-Agent for the requested context. `cellIndex == nil`
    /// uses the single-mode UA; `0…3` returns the persistent cell UA.
    func userAgent(forCell cellIndex: Int?) -> String {
        if let cellIndex, cellUserAgents.indices.contains(cellIndex) {
            return cellUserAgents[cellIndex]
        }
        return singleUserAgent
    }

    /// Re-rolls the single-mode UA.
    func regenerateSingle() {
        singleUserAgent = Self.generateRandomUserAgent()
    }

    /// Re-rolls a specific quad cell's persistent UA.
    func regenerateCell(_ cellIndex: Int) {
        guard cellUserAgents.indices.contains(cellIndex) else { return }
        let ua = Self.generateRandomUserAgent()
        cellUserAgents[cellIndex] = ua
        UserDefaults.standard.set(ua, forKey: Keys.cellUAPrefix + String(cellIndex))
    }

    // MARK: - Random UA

    private static let iosVersions: [(major: Int, minor: Int, patch: Int)] = [
        (16, 4, 1), (16, 5, 0), (16, 6, 1), (16, 7, 0),
        (17, 0, 3), (17, 1, 2), (17, 2, 1), (17, 3, 1), (17, 4, 1), (17, 5, 1), (17, 6, 1), (17, 7, 0),
        (18, 0, 0), (18, 1, 0), (18, 1, 1), (18, 2, 0), (18, 3, 0)
    ]

    private static let webkitBuilds: [String] = [
        "605.1.15", "605.1.14"
    ]

    private static let mobileBuilds: [String] = [
        "15E148", "21A329", "21B91", "21C66", "21D50", "21E236",
        "21F90", "21G93", "21H16", "22A340", "22B91", "22D60"
    ]

    static func generateRandomUserAgent() -> String {
        let ios = iosVersions.randomElement() ?? (17, 5, 1)
        let osVer = "\(ios.major)_\(ios.minor)_\(ios.patch)"
        let safariVer = "\(ios.major).\(ios.minor)"
        let webkit = webkitBuilds.randomElement() ?? "605.1.15"
        let mobile = mobileBuilds.randomElement() ?? "15E148"
        return "Mozilla/5.0 (iPhone; CPU iPhone OS \(osVer) like Mac OS X) AppleWebKit/\(webkit) (KHTML, like Gecko) Version/\(safariVer) Mobile/\(mobile) Safari/604.1"
    }

    // MARK: - Display helpers

    func uaSuffix(_ ua: String, maxLen: Int = 24) -> String {
        guard ua.count > maxLen else { return ua }
        return "…" + String(ua.suffix(maxLen))
    }
}
