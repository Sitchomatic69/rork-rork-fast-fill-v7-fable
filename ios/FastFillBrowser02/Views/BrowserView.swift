import SwiftUI
import SwiftData

struct BrowserView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var viewModel = BrowserViewModel()
    @FocusState private var isURLBarFocused: Bool

    // Swipe-to-hide state for the live RCR queue pill(s).
    @State private var singlePillHidden: Bool = false
    @State private var singlePillDrag: CGFloat = 0
    @State private var quadPillsHidden: [Bool] = [false, false, false, false]
    @State private var quadPillsDrag: [CGFloat] = [0, 0, 0, 0]
    @State private var rcrPressed: Bool = false

    var body: some View {
        ZStack(alignment: .bottom) {
            VStack(spacing: 0) {
                urlBar
                progressBar
                webContent
                bottomToolbar
            }

            if viewModel.toastVisible, let message = viewModel.toastMessage {
                ToastView(message: message)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .padding(.bottom, 70)
                    .zIndex(100)
            }

            if viewModel.isRCRRunning || (viewModel.rcrTotal > 0 && !viewModel.isQuadMode) {
                hideablePill(
                    hidden: $singlePillHidden,
                    drag: $singlePillDrag,
                    label: "Show RCR queue"
                ) {
                    singleQueuePill
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .padding(.bottom, 70)
                .zIndex(99)
            } else if viewModel.isQuadMode && (viewModel.quadController.anyRCRRunning || viewModel.quadController.sessions.contains(where: { $0.rcrTotal > 0 })) {
                quadQueuePills
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .padding(.bottom, 70)
                    .zIndex(99)
            }
        }
        .onChange(of: viewModel.isQuadMode) { _, isQuad in
            viewModel.handleQuadToggle(enteringQuad: isQuad)
        }
        .onChange(of: viewModel.quadController.focusedIndex) { _, _ in
            if viewModel.isQuadMode, !viewModel.isURLBarEditing {
                viewModel.updateURLBar()
            }
        }
        .onChange(of: viewModel.isRCRRunning) { _, running in
            if running { isURLBarFocused = false; dismissKeyboard() }
        }
        .onChange(of: viewModel.quadController.anyRCRRunning) { _, running in
            if running { isURLBarFocused = false; dismissKeyboard() }
        }
        .task {
            viewModel.setup(modelContext: modelContext)
            await WebViewConfigurationFactory.shared.prepare()
            DNSPrewarmService.shared.prewarmTopDomains(modelContext: modelContext)
        }
        .sheet(item: $viewModel.presentedSheet, onDismiss: {
            viewModel.reloadExcludedDomains()
            viewModel.invalidateCredentialCache()
        }) { sheet in
            sheetContent(for: sheet)
        }
        .alert("Save Login?", isPresented: $viewModel.isShowingSaveCredentialAlert) {
            Button("Save") { viewModel.saveDetectedCredential() }
            Button("Not Now", role: .cancel) {}
        } message: {
            Text("Save credentials for \(viewModel.activeTab?.domain ?? "this site")?\nUsername: \(viewModel.detectedUsername)")
        }
    }

    @ViewBuilder
    private func sheetContent(for sheet: PresentedSheet) -> some View {
        switch sheet {
        case .tabs:
            TabManagerView(viewModel: viewModel)
        case .vault:
            NavigationStack { VaultView() }
        case .siteSettings(let domain):
            NavigationStack { SiteSettingsView(domain: domain) }
        case .settings:
            NavigationStack { AppSettingsView() }
        case .bookmarks:
            NavigationStack { BookmarksView(viewModel: viewModel) }
        case .history:
            NavigationStack { HistoryView(viewModel: viewModel) }
        case .results:
            NavigationStack { ResultsView() }
        }
    }

    private var urlBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "lock.fill")
                .font(.caption)
                .foregroundStyle(viewModel.activeTab?.url?.scheme == "https" ? .green : .secondary)

            TextField("Search or enter URL", text: $viewModel.urlBarText)
                .textFieldStyle(.plain)
                .font(.callout)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
                .submitLabel(.go)
                .focused($isURLBarFocused)
                .disabled(isAnyRCRRunning)
                .onSubmit {
                    viewModel.navigateTo(viewModel.urlBarText)
                    isURLBarFocused = false
                }
                .onChange(of: isURLBarFocused) { _, focused in
                    viewModel.isURLBarEditing = focused
                    if focused {
                        DispatchQueue.main.async {
                            UIApplication.shared.sendAction(
                                #selector(UIResponder.selectAll(_:)),
                                to: nil, from: nil, for: nil
                            )
                        }
                    } else {
                        viewModel.updateURLBar()
                    }
                }

            if isURLBarFocused && !viewModel.urlBarText.isEmpty {
                Button {
                    viewModel.urlBarText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            } else if viewModel.activeTab?.isLoading == true {
                ProgressView()
                    .scaleEffect(0.7)
            }

            Menu {
                Button("Site Settings", systemImage: "gearshape") {
                    if let domain = viewModel.activeTab?.domain, !domain.isEmpty {
                        viewModel.presentedSheet = .siteSettings(domain)
                    }
                }
                Button("Add Bookmark", systemImage: "bookmark") {
                    viewModel.addBookmark()
                }
                Button("Share", systemImage: "square.and.arrow.up") {}
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.body)
                    .foregroundStyle(.primary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color(.secondarySystemBackground))
        .clipShape(.rect(cornerRadius: 12))
        .padding(.horizontal, 12)
        .padding(.top, 4)
        .padding(.bottom, 2)
    }

    private var progressBar: some View {
        GeometryReader { geo in
            if viewModel.activeTab?.isLoading == true {
                Rectangle()
                    .fill(Color.accentColor)
                    .frame(
                        width: geo.size.width * (viewModel.activeTab?.estimatedProgress ?? 0),
                        height: 2
                    )
                    .animation(.linear, value: viewModel.activeTab?.estimatedProgress)
            }
        }
        .frame(height: 2)
    }

    private var webContent: some View {
        ZStack {
            if viewModel.isQuadMode {
                QuadBrowserView(controller: viewModel.quadController)
            } else if let tab = viewModel.activeTab {
                WebViewWrapper(tab: tab, viewModel: viewModel)
                    .id(tab.id)
            } else {
                newTabPage
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var newTabPage: some View {
        VStack(spacing: 24) {
            Image(systemName: "bolt.shield.fill")
                .font(.system(size: 56))
                .foregroundStyle(.linearGradient(
                    colors: [.cyan, .blue],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ))

            Text("Fast Fill Browser")
                .font(.title2.bold())

            Text("The smartest login browser")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
    }

    // MARK: - Bottom toolbar

    private var bottomToolbar: some View {
        HStack(spacing: 0) {
            toolbarButton(icon: "chevron.left", disabled: viewModel.activeTab?.canGoBack != true) {
                viewModel.goBack()
            }

            toolbarButton(icon: "chevron.right", disabled: viewModel.activeTab?.canGoForward != true) {
                viewModel.goForward()
            }

            rcrButton

            toolbarButton(icon: "flame.fill", tint: .red) {
                viewModel.burnCurrentTab()
            }
            .overlay(alignment: .topTrailing) {
                if viewModel.rcrBurnFlash > 0 {
                    Text("\(viewModel.rcrBurnFlash)")
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(.red, in: .capsule)
                        .offset(x: 6, y: -4)
                }
            }

            quadModeToggle

            moreMenu
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(.regularMaterial)
                .shadow(color: .black.opacity(0.08), radius: 8, y: 2)
        )
        .padding(.horizontal, 10)
        .padding(.bottom, 6)
    }

    private var rcrButton: some View {
        Button {
            viewModel.toggleRCR()
        } label: {
            ZStack {
                // Soft pulsing ring during active runs
                if viewModel.isRCRRunning || viewModel.quadController.anyRCRRunning {
                    Circle()
                        .stroke(
                            LinearGradient(colors: [.cyan, .blue], startPoint: .topLeading, endPoint: .bottomTrailing),
                            lineWidth: 2
                        )
                        .frame(width: 50, height: 50)
                        .scaleEffect(viewModel.isRCRRunning ? 1.12 : 1)
                        .opacity(viewModel.isRCRRunning ? 0.6 : 0)
                        .animation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true), value: viewModel.isRCRRunning)
                }

                Circle()
                    .fill(.linearGradient(
                        colors: [.cyan, .blue],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ))
                    .frame(width: 44, height: 44)

                if viewModel.isRCRRunning {
                    Circle()
                        .trim(from: 0, to: rcrProgressFraction)
                        .stroke(
                            Color.white.opacity(0.95),
                            style: StrokeStyle(lineWidth: 2.5, lineCap: .round)
                        )
                        .rotationEffect(.degrees(-90))
                        .frame(width: 40, height: 40)
                        .animation(.easeInOut(duration: 0.25), value: viewModel.rcrIndex)

                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.white)
                        .frame(width: 10, height: 10)
                } else {
                    Text("RCR")
                        .font(.system(.caption2, design: .rounded, weight: .black))
                        .foregroundStyle(.white)
                        .kerning(0.5)
                }
            }
            .scaleEffect(rcrPressed ? 0.92 : 1.0)
            .animation(.spring(response: 0.3, dampingFraction: 0.6), value: rcrPressed)
        }
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in rcrPressed = true }
                .onEnded { _ in rcrPressed = false }
        )
        .sensoryFeedback(.impact(weight: .light), trigger: viewModel.rcrIndex)
        .sensoryFeedback(.success, trigger: viewModel.rcrStatus == .success)
        .sensoryFeedback(.impact(weight: .heavy), trigger: viewModel.rcrBurnFlash)
        .frame(maxWidth: .infinity)
    }

    private var rcrProgressFraction: CGFloat {
        guard viewModel.rcrTotal > 0 else { return 0 }
        return CGFloat(min(viewModel.rcrIndex, viewModel.rcrTotal)) / CGFloat(viewModel.rcrTotal)
    }

    private var quadModeToggle: some View {
        Button {
            viewModel.isQuadMode.toggle()
            isURLBarFocused = false
            dismissKeyboard()
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .stroke(viewModel.isQuadMode ? .cyan : .secondary.opacity(0.5), lineWidth: 1.5)
                    .frame(width: 28, height: 28)

                VStack(spacing: 2) {
                    HStack(spacing: 2) {
                        quadCell(filled: true)
                        quadCell(filled: viewModel.isQuadMode)
                    }
                    HStack(spacing: 2) {
                        quadCell(filled: viewModel.isQuadMode)
                        quadCell(filled: viewModel.isQuadMode)
                    }
                }
            }
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
        }
        .frame(maxWidth: .infinity)
    }

    private func quadCell(filled: Bool) -> some View {
        RoundedRectangle(cornerRadius: 1.5)
            .fill(filled ? Color.cyan : Color.secondary.opacity(0.35))
            .frame(width: 9, height: 9)
    }

    // MARK: - Single queue pill

    private var singleQueuePill: some View {
        QueuePillView(
            title: "RCR",
            titleColor: .cyan,
            statusDotColor: statusColor(viewModel.rcrStatus),
            statusLabel: statusLabel(viewModel.rcrStatus),
            isWaitingPulse: viewModel.rcrStatus == .waiting || viewModel.rcrStatus == .filling,
            total: viewModel.rcrTotal,
            completedCount: viewModel.rcrCompletedIDs.count,
            upcoming: viewModel.queueSnapshot(upcomingLimit: 8),
            completed: viewModel.completedSnapshot(),
            pulseTrigger: viewModel.rcrIndex,
            onViewResults: {
                viewModel.presentedSheet = .results
            }
        )
    }

    // MARK: - Quad pills

    private var quadQueuePills: some View {
        VStack(spacing: 4) {
            ForEach(Array(viewModel.quadController.sessions.enumerated()), id: \.element.id) { idx, session in
                hideablePill(
                    hidden: Binding(
                        get: { quadPillsHidden.indices.contains(idx) ? quadPillsHidden[idx] : false },
                        set: { newValue in
                            if quadPillsHidden.indices.contains(idx) { quadPillsHidden[idx] = newValue }
                        }
                    ),
                    drag: Binding(
                        get: { quadPillsDrag.indices.contains(idx) ? quadPillsDrag[idx] : 0 },
                        set: { newValue in
                            if quadPillsDrag.indices.contains(idx) { quadPillsDrag[idx] = newValue }
                        }
                    ),
                    label: "Show \(session.id)"
                ) {
                    QueuePillView(
                        title: session.id,
                        titleColor: .cyan,
                        statusDotColor: quadStatusColor(session.rcrStatus),
                        statusLabel: quadStatusLabel(session.rcrStatus),
                        isWaitingPulse: session.rcrStatus == .waiting || session.rcrStatus == .filling,
                        total: session.rcrTotal,
                        completedCount: session.rcrCompletedIDs.count,
                        upcoming: viewModel.quadController.queueSnapshot(for: session, upcomingLimit: 4),
                        completed: viewModel.quadController.completedSnapshot(for: session),
                        pulseTrigger: session.rcrIndex,
                        onViewResults: {
                            viewModel.presentedSheet = .results
                        }
                    )
                }
            }
        }
    }

    /// Wraps a pill so it can be swiped down to hide. When hidden, shows a
    /// tappable chevron tab to bring it back.
    @ViewBuilder
    private func hideablePill<Content: View>(
        hidden: Binding<Bool>,
        drag: Binding<CGFloat>,
        label: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        if hidden.wrappedValue {
            Button {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                    hidden.wrappedValue = false
                    drag.wrappedValue = 0
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.up")
                        .font(.caption2.bold())
                    Text(label)
                        .font(.caption2.weight(.bold))
                }
                .foregroundStyle(.cyan)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(.ultraThinMaterial, in: .capsule)
                .overlay(
                    Capsule().strokeBorder(.cyan.opacity(0.35), lineWidth: 0.5)
                )
            }
            .buttonStyle(.plain)
            .transition(.opacity.combined(with: .move(edge: .bottom)))
        } else {
            content()
                .offset(y: drag.wrappedValue)
                .gesture(
                    DragGesture()
                        .onChanged { value in
                            drag.wrappedValue = max(0, value.translation.height)
                        }
                        .onEnded { value in
                            if value.translation.height > 60 {
                                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                                    hidden.wrappedValue = true
                                    drag.wrappedValue = 0
                                }
                            } else {
                                withAnimation(.spring) { drag.wrappedValue = 0 }
                            }
                        }
                )
        }
    }

    // MARK: - Status helpers

    private func statusColor(_ s: BrowserViewModel.RCRStatus) -> Color {
        switch s {
        case .idle: return .secondary
        case .navigating: return .blue
        case .filling: return .cyan
        case .submitting: return .indigo
        case .waiting: return .yellow
        case .burning: return .orange
        case .success: return .green
        }
    }

    private func statusLabel(_ s: BrowserViewModel.RCRStatus) -> String {
        switch s {
        case .idle: return "idle"
        case .navigating: return "loading"
        case .filling: return "filling"
        case .submitting: return "submitting"
        case .waiting: return "watching"
        case .burning: return "burning"
        case .success: return "success"
        }
    }

    private func quadStatusColor(_ s: QuadSession.Status) -> Color {
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

    private func quadStatusLabel(_ s: QuadSession.Status) -> String {
        switch s {
        case .idle: return "idle"
        case .navigating: return "loading"
        case .filling: return "filling"
        case .submitting: return "submitting"
        case .waiting: return "watching"
        case .burning: return "burning"
        case .success: return "success"
        case .finished: return "done"
        }
    }

    // MARK: - More menu

    private var moreMenu: some View {
        Menu {
            Button("Vault", systemImage: "lock.shield") {
                viewModel.presentedSheet = .vault
            }
            Button("Results", systemImage: "photo.on.rectangle.angled") {
                viewModel.presentedSheet = .results
            }
            Divider()
            Button("Tabs (\(viewModel.tabs.count))", systemImage: "square.on.square") {
                viewModel.presentedSheet = .tabs
            }
            Button("Bookmarks", systemImage: "bookmark") {
                viewModel.presentedSheet = .bookmarks
            }
            Button("History", systemImage: "clock") {
                viewModel.presentedSheet = .history
            }
            Divider()
            Button("New Tab", systemImage: "plus") {
                viewModel.addNewTab()
            }
            Button("Reload", systemImage: "arrow.clockwise") {
                viewModel.reload()
            }
            Divider()
            Button("Settings", systemImage: "gear") {
                viewModel.presentedSheet = .settings
            }
        } label: {
            Image(systemName: "line.3.horizontal")
                .font(.body)
                .foregroundStyle(.primary)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .frame(maxWidth: .infinity)
    }

    private func toolbarButton(
        icon: String,
        disabled: Bool = false,
        tint: Color? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.body)
                .foregroundStyle(disabled ? AnyShapeStyle(.tertiary) : AnyShapeStyle(tint ?? .primary))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .disabled(disabled)
        .frame(maxWidth: .infinity)
    }

    private var isAnyRCRRunning: Bool {
        viewModel.isRCRRunning || viewModel.quadController.anyRCRRunning
    }

    private func dismissKeyboard() {
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil, from: nil, for: nil
        )
    }
}
