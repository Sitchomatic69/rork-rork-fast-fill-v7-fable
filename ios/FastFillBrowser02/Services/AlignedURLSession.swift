import Foundation

/// Native-networking surface aligned to the active `BrowsingProfile`.
///
/// Every URLSession the app creates for first-party traffic flows through
/// `AlignedURLSession.shared`. The session reads the current persona
/// (User-Agent, Accept-Language, Sec-CH-UA hints) and stamps every outbound
/// request with the same header set the embedded WKWebView would send for the
/// same persona — closing the easy correlation path of "UA in WebView ≠ UA
/// in URLSession".
///
/// TLS-fingerprint alignment (JA3/JA4) is intentionally NOT attempted at this
/// layer: Apple's URLSession TLS stack already produces the same ALPN/cipher
/// shape as WKWebView on the same iOS build, so as long as both run on the
/// same device, JA3/JA4 align by construction. The risk vector is HTTP-layer
/// header divergence, which is exactly what this class neutralizes.
@MainActor
final class AlignedURLSession {
    static let shared = AlignedURLSession()

    private(set) var session: URLSession

    private init() {
        self.session = Self.buildSession(profile: ProfileManager.cachedSnapshot())
    }

    /// Call after `ProfileManager.cycle(...)` completes (in the rare path
    /// where we don't cold-restart) to rebuild the session under the new
    /// persona.
    func rebuild() {
        session.invalidateAndCancel()
        session = Self.buildSession(profile: ProfileManager.cachedSnapshot())
    }

    private static func buildSession(profile: BrowsingProfile) -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.httpAdditionalHeaders = [
            "User-Agent": profile.userAgent,
            "Accept-Language": profile.acceptLanguage,
            "Sec-CH-UA": profile.secChUa,
            "Sec-CH-UA-Mobile": profile.secChUaMobile,
            "Sec-CH-UA-Platform": profile.secChUaPlatform
        ]
        cfg.httpCookieStorage = HTTPCookieStorage.shared
        cfg.httpCookieAcceptPolicy = .onlyFromMainDocumentDomain
        cfg.tlsMinimumSupportedProtocolVersion = .TLSv12
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.urlCache = nil
        return URLSession(configuration: cfg)
    }
}
