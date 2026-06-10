import SwiftUI
import WebKit

struct WebViewWrapper: UIViewRepresentable {
    let tab: BrowserTab
    let viewModel: BrowserViewModel

    func makeUIView(context: Context) -> WKWebView {
        let config = WebViewConfigurationFactory.shared.makeConfiguration()
        config.userContentController.add(ScriptMessageProxy(delegate: context.coordinator), name: "rcrObserver")
        config.userContentController.add(ScriptMessageProxy(delegate: context.coordinator), name: "loginResponse")

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        webView.isInspectable = true
        webView.customUserAgent = ProfileManager.cachedSnapshot().userAgent
        WebViewLifecycleRegistry.shared.register(webView)

        tab.webView = webView
        tab.isWebViewActive = true
        if let url = tab.url {
            webView.load(URLRequest(url: url))
        }

        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        if tab.webView !== webView {
            tab.webView = webView
        }
    }

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "rcrObserver")
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "loginResponse")
        WebViewLifecycleRegistry.shared.unregister(webView)
        coordinator.tab?.webView = nil
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(tab: tab, viewModel: viewModel)
    }

    class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        weak var tab: BrowserTab?
        let viewModel: BrowserViewModel

        init(tab: BrowserTab, viewModel: BrowserViewModel) {
            self.tab = tab
            self.viewModel = viewModel
        }

        nonisolated func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            Task { @MainActor [weak self] in
                guard let self, let tab = self.tab else { return }
                tab.isLoading = true
                tab.estimatedProgress = 0.1
                tab.canGoBack = webView.canGoBack
                tab.canGoForward = webView.canGoForward
            }
        }

        nonisolated func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            Task { @MainActor [weak self] in
                guard let self, let tab = self.tab else { return }
                tab.url = webView.url
                tab.title = webView.title ?? "Loading..."
                tab.estimatedProgress = max(tab.estimatedProgress, 0.5)
                tab.canGoBack = webView.canGoBack
                tab.canGoForward = webView.canGoForward
                viewModel.updateURLBar()
            }
        }

        nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            Task { @MainActor [weak self] in
                guard let self, let tab = self.tab else { return }
                tab.isLoading = false
                tab.estimatedProgress = 1.0
                tab.url = webView.url
                tab.title = webView.title ?? tab.domain
                tab.canGoBack = webView.canGoBack
                tab.canGoForward = webView.canGoForward
                viewModel.updateURLBar()

                if let url = webView.url?.absoluteString {
                    viewModel.addHistoryEntry(url: url, title: tab.title)
                }

                if viewModel.isRCRRunning {
                    viewModel.rcrPageDidFinish()
                }
            }
        }

        nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            Task { @MainActor [weak self] in
                guard let self, let tab = self.tab else { return }
                tab.isLoading = false
                tab.estimatedProgress = 0
            }
        }

        nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            Task { @MainActor [weak self] in
                guard let self, let tab = self.tab else { return }
                tab.isLoading = false
                tab.estimatedProgress = 0
            }
        }

        nonisolated func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction
        ) async -> WKNavigationActionPolicy {
            let navType = await MainActor.run { navigationAction.navigationType }
            if navType == .formSubmitted {
                await MainActor.run {
                    if !viewModel.isRCRRunning {
                        viewModel.detectAndOfferSave()
                    }
                }
            }
            return .allow
        }

        nonisolated func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            let name = message.name
            let body = message.body as? [String: Any] ?? [:]
            Task { @MainActor in
                switch name {
                case "rcrObserver":
                    viewModel.handleRCRStateMessage(body)
                case "loginResponse":
                    viewModel.handleLoginResponseMessage(body)
                default: break
                }
            }
        }
    }
}
