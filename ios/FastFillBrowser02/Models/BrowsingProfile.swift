import Foundation

/// Immutable, internally-consistent snapshot of one believable iOS browsing
/// persona. Every WKWebView and every URLSession in the app aligns to a
/// single active `BrowsingProfile` at any moment.
///
/// All fields are deterministic w.r.t. the persona — there is no per-request
/// randomization. Real iOS devices of the same model emit near-identical
/// signals; adding noise on top makes a profile MORE unique, not less.
nonisolated struct BrowsingProfile: Codable, Hashable, Sendable {
    // MARK: - Identity
    let id: UUID
    let createdAt: Date
    let deviceModelKey: String         // "iphone16,2" etc — internal key

    // MARK: - UA + Client Hints
    let userAgent: String
    let secChUa: String                // mobile UA-CH brand list
    let secChUaMobile: String          // "?1"
    let secChUaPlatform: String        // "\"iOS\""
    let acceptLanguage: String         // server-side Accept-Language

    // MARK: - Navigator / Screen
    let platform: String               // "iPhone" / "iPad" / "MacIntel" (Safari iPad lies)
    let hardwareConcurrency: Int
    let deviceMemoryGB: Int            // 4 / 6 / 8
    let maxTouchPoints: Int            // 5 on iOS
    let screenWidth: Int               // CSS pixels (logical)
    let screenHeight: Int
    let screenAvailWidth: Int
    let screenAvailHeight: Int
    let devicePixelRatio: Double       // 2 or 3
    let colorDepth: Int                // 24/30

    // MARK: - Locale / Timezone
    let locale: String                 // "en-AU"
    let languages: [String]            // ["en-AU", "en"]
    let timezone: String               // IANA "Australia/Perth"

    // MARK: - WebGL
    let webglVendor: String            // "Apple Inc."
    let webglRenderer: String          // "Apple GPU"
    let webglUnmaskedVendor: String    // "Apple Inc."
    let webglUnmaskedRenderer: String  // "Apple GPU"
    let webglVersion: String           // "WebGL 2.0"
    let webglShadingLanguage: String   // "WebGL GSL ES 3.00"

    // MARK: - Audio
    let audioSampleRate: Int           // 48000 on iOS

    // MARK: - Subtle, real-device variance
    /// 0…1 — drives sub-pixel font-rasterization variance within the spec
    /// envelope of real iOS devices. Single-digit deltas only.
    let rasterVariance: Double
    /// 0…1 — selects which WebGL precision-format edge value the persona
    /// reports (real devices vary at the last bit).
    let webglPrecisionSeed: Double
    /// Deterministic audio fingerprint nudge — well below the per-device
    /// noise floor real devices already exhibit.
    let audioFingerprintSeed: Double

    // MARK: - Convenience
    var origin: String { "https://" + (URL(string: "https://example.com")?.host ?? "example.com") }
}

// MARK: - Real iOS Device Matrix

/// 24 validated personas spanning iPhone 12 mini through iPad Pro M4 and
/// iOS 16.x through 18.x. Selecting from this curated set guarantees the
/// emitted signals correspond to a device that actually shipped.
nonisolated enum BrowsingProfileMatrix {
    struct DeviceSpec {
        let modelKey: String
        let isPad: Bool
        let screenW: Int
        let screenH: Int
        let dpr: Double
        let cores: Int
        let memoryGB: Int
        /// iOS versions this device supports — the persona picks one.
        let supportedIOS: [(Int, Int, Int)]
    }

    static let devices: [DeviceSpec] = [
        // iPhones — (CSS-px logical, dpr)
        .init(modelKey: "iphone13,1", isPad: false, screenW: 360, screenH: 780, dpr: 3, cores: 6, memoryGB: 4,
              supportedIOS: [(16,7,0),(17,5,1),(17,6,1),(18,1,1)]),                                // iPhone 12 mini
        .init(modelKey: "iphone13,2", isPad: false, screenW: 390, screenH: 844, dpr: 3, cores: 6, memoryGB: 4,
              supportedIOS: [(16,7,0),(17,5,1),(17,6,1),(18,1,1)]),                                // iPhone 12
        .init(modelKey: "iphone13,3", isPad: false, screenW: 390, screenH: 844, dpr: 3, cores: 6, memoryGB: 6,
              supportedIOS: [(16,7,0),(17,5,1),(17,6,1),(18,1,1)]),                                // iPhone 12 Pro
        .init(modelKey: "iphone13,4", isPad: false, screenW: 428, screenH: 926, dpr: 3, cores: 6, memoryGB: 6,
              supportedIOS: [(16,7,0),(17,5,1),(17,6,1),(18,1,1)]),                                // iPhone 12 Pro Max
        .init(modelKey: "iphone14,4", isPad: false, screenW: 375, screenH: 812, dpr: 3, cores: 6, memoryGB: 4,
              supportedIOS: [(17,5,1),(17,6,1),(18,1,1),(18,2,0)]),                                // iPhone 13 mini
        .init(modelKey: "iphone14,5", isPad: false, screenW: 390, screenH: 844, dpr: 3, cores: 6, memoryGB: 4,
              supportedIOS: [(17,5,1),(17,6,1),(18,1,1),(18,2,0)]),                                // iPhone 13
        .init(modelKey: "iphone14,2", isPad: false, screenW: 390, screenH: 844, dpr: 3, cores: 6, memoryGB: 6,
              supportedIOS: [(17,5,1),(17,6,1),(18,1,1),(18,2,0)]),                                // iPhone 13 Pro
        .init(modelKey: "iphone14,3", isPad: false, screenW: 428, screenH: 926, dpr: 3, cores: 6, memoryGB: 6,
              supportedIOS: [(17,5,1),(17,6,1),(18,1,1),(18,2,0)]),                                // iPhone 13 Pro Max
        .init(modelKey: "iphone14,7", isPad: false, screenW: 390, screenH: 844, dpr: 3, cores: 6, memoryGB: 6,
              supportedIOS: [(17,6,1),(18,1,1),(18,2,0),(18,3,0)]),                                // iPhone 14
        .init(modelKey: "iphone14,8", isPad: false, screenW: 428, screenH: 926, dpr: 3, cores: 6, memoryGB: 6,
              supportedIOS: [(17,6,1),(18,1,1),(18,2,0),(18,3,0)]),                                // iPhone 14 Plus
        .init(modelKey: "iphone15,2", isPad: false, screenW: 393, screenH: 852, dpr: 3, cores: 6, memoryGB: 6,
              supportedIOS: [(17,6,1),(18,1,1),(18,2,0),(18,3,0)]),                                // iPhone 14 Pro
        .init(modelKey: "iphone15,3", isPad: false, screenW: 430, screenH: 932, dpr: 3, cores: 6, memoryGB: 6,
              supportedIOS: [(17,6,1),(18,1,1),(18,2,0),(18,3,0)]),                                // iPhone 14 Pro Max
        .init(modelKey: "iphone15,4", isPad: false, screenW: 393, screenH: 852, dpr: 3, cores: 6, memoryGB: 6,
              supportedIOS: [(18,1,1),(18,2,0),(18,3,0)]),                                          // iPhone 15
        .init(modelKey: "iphone15,5", isPad: false, screenW: 430, screenH: 932, dpr: 3, cores: 6, memoryGB: 6,
              supportedIOS: [(18,1,1),(18,2,0),(18,3,0)]),                                          // iPhone 15 Plus
        .init(modelKey: "iphone16,1", isPad: false, screenW: 393, screenH: 852, dpr: 3, cores: 6, memoryGB: 8,
              supportedIOS: [(18,1,1),(18,2,0),(18,3,0)]),                                          // iPhone 15 Pro
        .init(modelKey: "iphone16,2", isPad: false, screenW: 430, screenH: 932, dpr: 3, cores: 6, memoryGB: 8,
              supportedIOS: [(18,1,1),(18,2,0),(18,3,0)]),                                          // iPhone 15 Pro Max
        .init(modelKey: "iphone17,3", isPad: false, screenW: 393, screenH: 852, dpr: 3, cores: 6, memoryGB: 8,
              supportedIOS: [(18,1,1),(18,2,0),(18,3,0)]),                                          // iPhone 16
        .init(modelKey: "iphone17,4", isPad: false, screenW: 430, screenH: 932, dpr: 3, cores: 6, memoryGB: 8,
              supportedIOS: [(18,1,1),(18,2,0),(18,3,0)]),                                          // iPhone 16 Plus
        .init(modelKey: "iphone17,1", isPad: false, screenW: 402, screenH: 874, dpr: 3, cores: 6, memoryGB: 8,
              supportedIOS: [(18,1,1),(18,2,0),(18,3,0)]),                                          // iPhone 16 Pro
        .init(modelKey: "iphone17,2", isPad: false, screenW: 440, screenH: 956, dpr: 3, cores: 6, memoryGB: 8,
              supportedIOS: [(18,1,1),(18,2,0),(18,3,0)]),                                          // iPhone 16 Pro Max

        // iPads (Safari on iPad reports platform="MacIntel" since iPadOS 13)
        .init(modelKey: "ipad13,4", isPad: true, screenW: 1024, screenH: 1366, dpr: 2, cores: 8, memoryGB: 8,
              supportedIOS: [(17,5,1),(17,6,1),(18,1,1),(18,2,0)]),                                // iPad Pro 12.9 M1
        .init(modelKey: "ipad14,5", isPad: true, screenW: 1024, screenH: 1366, dpr: 2, cores: 8, memoryGB: 8,
              supportedIOS: [(17,6,1),(18,1,1),(18,2,0),(18,3,0)]),                                // iPad Pro 12.9 M2
        .init(modelKey: "ipad16,5", isPad: true, screenW: 1024, screenH: 1366, dpr: 2, cores: 8, memoryGB: 8,
              supportedIOS: [(18,1,1),(18,2,0),(18,3,0)]),                                          // iPad Pro M4 13"
        .init(modelKey: "ipad14,3", isPad: true, screenW: 834, screenH: 1194, dpr: 2, cores: 8, memoryGB: 8,
              supportedIOS: [(17,6,1),(18,1,1),(18,2,0),(18,3,0)]),                                // iPad Pro 11 M2
    ]

    struct LocaleSpec {
        let bcp47: String          // "en-AU"
        let base: String           // "en"
        let timezones: [String]    // candidate timezones that pair believably
        let acceptLanguage: String
    }

    static let locales: [LocaleSpec] = [
        .init(bcp47: "en-AU", base: "en", timezones: ["Australia/Perth", "Australia/Sydney", "Australia/Melbourne"],
              acceptLanguage: "en-AU,en;q=0.9"),
        .init(bcp47: "en-US", base: "en", timezones: ["America/New_York", "America/Los_Angeles", "America/Chicago"],
              acceptLanguage: "en-US,en;q=0.9"),
        .init(bcp47: "en-GB", base: "en", timezones: ["Europe/London"],
              acceptLanguage: "en-GB,en;q=0.9"),
        .init(bcp47: "en-CA", base: "en", timezones: ["America/Toronto", "America/Vancouver"],
              acceptLanguage: "en-CA,en;q=0.9"),
        .init(bcp47: "fr-FR", base: "fr", timezones: ["Europe/Paris"],
              acceptLanguage: "fr-FR,fr;q=0.9,en;q=0.8"),
        .init(bcp47: "de-DE", base: "de", timezones: ["Europe/Berlin"],
              acceptLanguage: "de-DE,de;q=0.9,en;q=0.8"),
        .init(bcp47: "es-ES", base: "es", timezones: ["Europe/Madrid"],
              acceptLanguage: "es-ES,es;q=0.9,en;q=0.8"),
        .init(bcp47: "it-IT", base: "it", timezones: ["Europe/Rome"],
              acceptLanguage: "it-IT,it;q=0.9,en;q=0.8"),
        .init(bcp47: "ja-JP", base: "ja", timezones: ["Asia/Tokyo"],
              acceptLanguage: "ja-JP,ja;q=0.9,en;q=0.8"),
        .init(bcp47: "pt-BR", base: "pt", timezones: ["America/Sao_Paulo"],
              acceptLanguage: "pt-BR,pt;q=0.9,en;q=0.8"),
        .init(bcp47: "nl-NL", base: "nl", timezones: ["Europe/Amsterdam"],
              acceptLanguage: "nl-NL,nl;q=0.9,en;q=0.8"),
    ]

    /// Generates a brand-new, internally consistent persona. Optionally
    /// constrain the locale/timezone choice; pass `nil` for fully random.
    static func generate(preferredLocale: String? = nil,
                         preferredTimezone: String? = nil,
                         using rng: inout SystemRandomNumberGenerator) -> BrowsingProfile {
        let device = devices.randomElement(using: &rng) ?? devices[0]
        let ios = device.supportedIOS.randomElement(using: &rng) ?? (18, 1, 1)

        // Resolve locale + timezone (caller preference wins, but must remain plausible).
        let localeSpec: LocaleSpec = {
            if let pref = preferredLocale, !pref.isEmpty,
               let match = locales.first(where: { $0.bcp47 == pref }) {
                return match
            }
            return locales.randomElement(using: &rng) ?? locales[0]
        }()

        let timezone: String = {
            if let pref = preferredTimezone, !pref.isEmpty { return pref }
            return localeSpec.timezones.randomElement(using: &rng) ?? "UTC"
        }()

        // WebKit + Safari versions track iOS minor.
        let safariVer = "\(ios.0).\(ios.1)"
        let webkitVer = "605.1.15"
        let mobileBuild = pickMobileBuild(for: ios, using: &rng)

        let isPad = device.isPad
        let uaDevice = isPad
            ? "iPad; CPU OS \(ios.0)_\(ios.1)_\(ios.2) like Mac OS X"
            : "iPhone; CPU iPhone OS \(ios.0)_\(ios.1)_\(ios.2) like Mac OS X"

        let userAgent = "Mozilla/5.0 (\(uaDevice)) AppleWebKit/\(webkitVer) (KHTML, like Gecko) Version/\(safariVer) Mobile/\(mobileBuild) Safari/604.1"

        // Safari on iPad lies about platform: reports MacIntel.
        let platform = isPad ? "MacIntel" : "iPhone"

        // Apple Safari doesn't ship Client Hints, but we expose minimal values
        // that match a Safari-shaped browser so a stray probe sees "?1" mobile.
        let secChUa = "\"Not.A/Brand\";v=\"99\", \"Safari\";v=\"\(ios.0)\""
        let secChUaMobile = isPad ? "?0" : "?1"
        let secChUaPlatform = "\"iOS\""

        return BrowsingProfile(
            id: UUID(),
            createdAt: Date(),
            deviceModelKey: device.modelKey,
            userAgent: userAgent,
            secChUa: secChUa,
            secChUaMobile: secChUaMobile,
            secChUaPlatform: secChUaPlatform,
            acceptLanguage: localeSpec.acceptLanguage,
            platform: platform,
            hardwareConcurrency: device.cores,
            deviceMemoryGB: device.memoryGB,
            maxTouchPoints: 5,
            screenWidth: device.screenW,
            screenHeight: device.screenH,
            screenAvailWidth: device.screenW,
            screenAvailHeight: device.screenH,
            devicePixelRatio: device.dpr,
            colorDepth: 24,
            locale: localeSpec.bcp47,
            languages: [localeSpec.bcp47, localeSpec.base],
            timezone: timezone,
            webglVendor: "Apple Inc.",
            webglRenderer: "Apple GPU",
            webglUnmaskedVendor: "Apple Inc.",
            webglUnmaskedRenderer: "Apple GPU",
            webglVersion: "WebGL 2.0",
            webglShadingLanguage: "WebGL GLSL ES 3.00",
            audioSampleRate: 48000,
            rasterVariance: Double.random(in: 0.0...1.0, using: &rng),
            webglPrecisionSeed: Double.random(in: 0.0...1.0, using: &rng),
            audioFingerprintSeed: Double.random(in: 0.0...1.0, using: &rng)
        )
    }

    private static let mobileBuilds: [(majorMin: Int, builds: [String])] = [
        (16, ["20H18", "20H115", "20H240"]),
        (17, ["21A329", "21B91", "21C66", "21D50", "21E236", "21F90", "21G93", "21H16"]),
        (18, ["22A340", "22B91", "22D60", "22D63"])
    ]

    private static func pickMobileBuild(for ios: (Int, Int, Int), using rng: inout SystemRandomNumberGenerator) -> String {
        for entry in mobileBuilds where entry.majorMin == ios.0 {
            return entry.builds.randomElement(using: &rng) ?? "22A340"
        }
        return "22A340"
    }
}
