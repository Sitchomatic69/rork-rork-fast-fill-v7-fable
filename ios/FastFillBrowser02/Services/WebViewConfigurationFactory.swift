import WebKit

@MainActor
final class WebViewConfigurationFactory {
    static let shared = WebViewConfigurationFactory()
    
    private(set) var contentRuleList: WKContentRuleList?
    private(set) var isReady: Bool = false

    private init() {}

    func prepare() async {
        await compileContentRules()
        isReady = true
    }

    func makeConfiguration() -> WKWebViewConfiguration {
        return makeConfiguration(dataStore: nil)
    }

    /// Quad Mode entry point: builds a configuration backed by an isolated
    /// persistent data store keyed off `dataStoreID`. Pass `nil` to use the
    /// default (shared) store.
    func makeIsolatedConfiguration(dataStoreID: UUID) -> WKWebViewConfiguration {
        let store = WKWebsiteDataStore(forIdentifier: dataStoreID)
        return makeConfiguration(dataStore: store)
    }

    /// Re-fetches the current profile and returns the matching User-Agent.
    /// Callers use this to keep existing web views' customUserAgent in sync
    /// after the user changes their persona in Settings.
    static var currentUA: String { ProfileManager.cachedSnapshot().userAgent }

    private func makeConfiguration(dataStore: WKWebsiteDataStore?) -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        if let dataStore { config.websiteDataStore = dataStore }

        // Stealth bundle — full persona alignment (Navigator, Screen, WebGL,
        // Canvas, Audio, Intl, Permissions, WebRTC, Battery, Plugins, Connection)
        // injected before any page script.
        let profile = ProfileManager.cachedSnapshot()
        let stealthSource = StealthScripts.bundle(for: profile)
        if !stealthSource.isEmpty {
            let stealth = WKUserScript(
                source: stealthSource,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: false
            )
            config.userContentController.addUserScript(stealth)
        }

        let detectScript = WKUserScript(
            source: JavaScriptInjectionService.detectLoginFormScript(),
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        )
        config.userContentController.addUserScript(detectScript)

        let helperScript = WKUserScript(
            source: JavaScriptInjectionService.fillHelperScript(),
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        )
        config.userContentController.addUserScript(helperScript)

        if let ruleList = contentRuleList {
            config.userContentController.add(ruleList)
        }

        return config
    }

    private func compileContentRules() async {
        let rules = """
        [
            {"trigger":{"url-filter":".*","resource-type":["script"],"if-domain":["*doubleclick.net","*googlesyndication.com","*googleadservices.com","*google-analytics.com","*facebook.net","*facebook.com/tr","*analytics.google.com","*googletagmanager.com","*connect.facebook.net"]},"action":{"type":"block"}},
            {"trigger":{"url-filter":".*","resource-type":["script","image","raw"],"if-domain":["*hotjar.com","*mixpanel.com","*segment.io","*amplitude.com","*optimizely.com","*crazyegg.com","*mouseflow.com","*fullstory.com","*datadoghq.com","*newrelic.com","*sentry.io","*rollbar.com","*loggly.com","*heapanalytics.com","*adjust.com","*branch.io","*appsflyer.com","*singular.net","*kochava.com","*chartbeat.com","*parse.ly","*hubspot.com","*pardot.com","*marketo.com","*fingerprintjs.com","*thumbmarkjs.com","*clientjs.org","*browserleaks.com"]},"action":{"type":"block"}},
            {"trigger":{"url-filter":".*\\\\.ads\\\\..*"},"action":{"type":"block"}},
            {"trigger":{"url-filter":".*track(ing|er).*","resource-type":["script","raw"]},"action":{"type":"block"}},
            {"trigger":{"url-filter":".*analytics.*","resource-type":["script"],"unless-domain":["*ignitioncasino.*","*bovada.*","*slots.lv.*"]},"action":{"type":"block"}},
            {"trigger":{"url-filter":".*(fingerprint|fpjs|clientjs|browscap).*","resource-type":["script"]},"action":{"type":"block"}}
        ]
        """

        do {
            contentRuleList = try await WKContentRuleListStore.default().compileContentRuleList(
                forIdentifier: "FastFillBlocker",
                encodedContentRuleList: rules
            )
        } catch {}
    }
}
