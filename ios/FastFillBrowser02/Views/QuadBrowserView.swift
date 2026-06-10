import SwiftUI
import WebKit

/// A single cell of the Quad-Mode grid. Owns its own `WKWebView` backed by
/// the session's isolated `WKWebsiteDataStore` so cookies, cache and storage
/// are completely separated from the other three cells.
struct QuadCellWebView: UIViewRepresentable {
    let session: QuadSession
    let controller: QuadController

    func makeUIView(context: Context) -> WKWebView {
        let config = WebViewConfigurationFactory.shared.makeIsolatedConfiguration(dataStoreID: session.storeID)
        config.userContentController.add(ScriptMessageProxy(delegate: context.coordinator), name: "rcrObserver")

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        webView.isInspectable = true
        webView.customUserAgent = ProfileManager.cachedSnapshot().userAgent
        WebViewLifecycleRegistry.shared.register(webView)

        session.webView = webView
        if let url = session.url {
            webView.load(URLRequest(url: url))
        }
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        if session.webView !== webView {
            session.webView = webView
        }
    }

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "rcrObserver")
        WebViewLifecycleRegistry.shared.unregister(webView)
        coordinator.session.webView = nil
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(session: session, controller: controller)
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        let session: QuadSession
        let controller: QuadController

        init(session: QuadSession, controller: QuadController) {
            self.session = session
            self.controller = controller
        }

        nonisolated func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            Task { @MainActor in
                session.isLoading = true
                session.estimatedProgress = 0.1
                session.canGoBack = webView.canGoBack
                session.canGoForward = webView.canGoForward
            }
        }

        nonisolated func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            Task { @MainActor in
                session.url = webView.url
                session.title = webView.title ?? "Loading…"
                session.estimatedProgress = max(session.estimatedProgress, 0.5)
                controller.syncFocusedURLBarIfNeeded(session: session)
            }
        }

        nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            Task { @MainActor in
                session.isLoading = false
                session.estimatedProgress = 1.0
                session.url = webView.url
                session.title = webView.title ?? session.domain
                session.canGoBack = webView.canGoBack
                session.canGoForward = webView.canGoForward
                controller.syncFocusedURLBarIfNeeded(session: session)
                controller.cellPageDidFinish(session: session)
            }
        }

        nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            Task { @MainActor in
                session.isLoading = false
                session.estimatedProgress = 0
            }
        }

        nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            Task { @MainActor in
                session.isLoading = false
                session.estimatedProgress = 0
            }
        }

        nonisolated func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            guard message.name == "rcrObserver" else { return }
            let body = message.body as? [String: Any] ?? [:]
            Task { @MainActor in
                controller.handleRCRMessage(session: session, payload: body)
            }
        }
    }
}

/// 2×2 grid of four isolated browser sessions. The cell that's currently
/// "focused" (tap to switch) gets a cyan ring and is the target for the
/// shared URL bar / toolbar.
struct QuadBrowserView: View {
    @Bindable var controller: QuadController

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width / 2
            let h = geo.size.height / 2
            VStack(spacing: 1) {
                HStack(spacing: 1) {
                    cell(controller.sessions[0]).frame(width: w, height: h)
                    cell(controller.sessions[1]).frame(width: w, height: h)
                }
                HStack(spacing: 1) {
                    cell(controller.sessions[2]).frame(width: w, height: h)
                    cell(controller.sessions[3]).frame(width: w, height: h)
                }
            }
            .background(Color.black)
        }
    }

    private func cell(_ session: QuadSession) -> some View {
        let isFocused = controller.focusedIndex == session.index
        return ZStack {
            QuadCellWebView(session: session, controller: controller)

            // Top-left badge with session id and status dot.
            VStack {
                HStack {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(statusColor(session.rcrStatus))
                            .frame(width: 6, height: 6)
                        Text(session.id)
                            .font(.system(size: 10, weight: .heavy, design: .rounded))
                            .foregroundStyle(.white)
                        if session.rcrTotal > 0 {
                            Text("\(min(session.rcrIndex, session.rcrTotal))/\(session.rcrTotal)")
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.8))
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(.black.opacity(0.55), in: .capsule)
                    .padding(6)
                    Spacer(minLength: 0)
                }
                Spacer(minLength: 0)
            }

            if session.isLoading {
                VStack {
                    Spacer(minLength: 0)
                    GeometryReader { g in
                        Rectangle()
                            .fill(Color.cyan)
                            .frame(width: g.size.width * session.estimatedProgress, height: 1.5)
                    }
                    .frame(height: 1.5)
                }
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 0)
                .strokeBorder(isFocused ? Color.cyan : .clear, lineWidth: 2)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            controller.focusedIndex = session.index
        }
    }

    private func statusColor(_ s: QuadSession.Status) -> Color {
        switch s {
        case .idle: return .secondary
        case .navigating: return .blue
        case .filling: return .cyan
        case .submitting: return .indigo
        case .waiting: return .yellow
        case .burning: return .orange
        case .success: return .green
        case .finished: return .mint
        }
    }
}
