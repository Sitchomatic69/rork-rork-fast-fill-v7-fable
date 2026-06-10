import SwiftUI
import SwiftData

struct VaultView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Credential.domain) private var credentials: [Credential]
    @Query(sort: \ExcludedDomain.domain) private var excludedDomains: [ExcludedDomain]
    @State private var viewModel = VaultViewModel()
    @State private var showDeleteAllConfirmation: Bool = false
    @State private var showBulkDeleteConfirmation: Bool = false
    @State private var showBulkExcludeConfirmation: Bool = false
    @State private var showResults: Bool = false
    @State private var attemptCounts: [String: Int] = [:]

    private var excludedDomainSet: Set<String> {
        Set(excludedDomains.map { $0.domain })
    }

    private var filteredCredentials: [Credential] {
        // Credentials whose canonical domain is on the exclude list are hidden
        // from the active vault — they will instead appear in the "Excluded"
        // sheet. Canonicalizing the credential side here protects against older
        // credentials that may have been stored with a leading `www.`.
        let base = credentials.filter {
            !excludedDomainSet.contains(ExcludedDomain.canonicalize($0.domain))
        }
        guard !viewModel.searchText.isEmpty else { return base }
        let search = viewModel.searchText.lowercased()
        return base.filter {
            $0.domain.localizedStandardContains(search) ||
            $0.username.localizedStandardContains(search)
        }
    }

    /// Groups for the current sort option. Groups are ordered by the "best"
    /// credential in each group (e.g. most-recently-used domain first for
    /// `.recentlyUsed`) so the top of the list is always the most relevant.
    private var groupedCredentials: [(String, [Credential])] {
        // Vault is locked to strict alphabetical order (domain, then username)
        // so the RCR queue and the on-screen list always agree on position.
        let sorted = VaultViewModel.sortCredentials(filteredCredentials, by: .domain)
        var order: [String] = []
        var groups: [String: [Credential]] = [:]
        for credential in sorted {
            let key = credential.displayDomain
            if groups[key] == nil {
                order.append(key)
                groups[key] = []
            }
            groups[key, default: []].append(credential)
        }
        return order.map { ($0, groups[$0] ?? []) }
    }

    var body: some View {
        List {
            if !viewModel.isEditMode && viewModel.searchText.isEmpty {
                Section {
                    Button {
                        showResults = true
                    } label: {
                        HStack {
                            Image(systemName: "photo.on.rectangle.angled")
                                .foregroundStyle(.cyan)
                            Text("Results")
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundStyle(.quaternary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }

            if !viewModel.isEditMode && viewModel.searchText.isEmpty && !excludedDomains.isEmpty {
                Section {
                    Button {
                        viewModel.isShowingExcludedDomains = true
                    } label: {
                        HStack {
                            Image(systemName: "nosign")
                                .foregroundStyle(.orange)
                            Text("Excluded Domains")
                            Spacer()
                            Text("\(excludedDomains.count)")
                                .foregroundStyle(.secondary)
                                .font(.subheadline)
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundStyle(.quaternary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }

            ForEach(groupedCredentials, id: \.0) { domain, creds in
                Section(domain) {
                    ForEach(creds) { credential in
                        credentialRowButton(credential)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .environment(\.editMode, editModeBinding)
        .overlay {
            if credentials.isEmpty && excludedDomains.isEmpty {
                ContentUnavailableView(
                    "No Saved Credentials",
                    systemImage: "lock.shield",
                    description: Text("Add credentials manually or import from another browser")
                )
            } else if filteredCredentials.isEmpty && !viewModel.searchText.isEmpty {
                ContentUnavailableView.search(text: viewModel.searchText)
            }
        }
        .searchable(text: $viewModel.searchText, prompt: "Search credentials")
        .navigationTitle("Vault")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
        .safeAreaInset(edge: .bottom) {
            if viewModel.isEditMode {
                bulkActionBar
            }
        }
        .sheet(isPresented: $viewModel.isShowingAddCredential) {
            NavigationStack { CredentialFormView() }
        }
        .sheet(item: $viewModel.selectedCredential) { credential in
            NavigationStack { CredentialDetailView(credential: credential) }
        }
        .sheet(isPresented: $viewModel.isShowingImport) {
            NavigationStack { ImportCredentialsView() }
        }
        .sheet(isPresented: $viewModel.isShowingPasswordGenerator) {
            NavigationStack { PasswordGeneratorView() }
        }
        .sheet(isPresented: $viewModel.isShowingExcludedDomains) {
            NavigationStack { ExcludedDomainsView() }
        }
        .sheet(isPresented: $showResults) {
            NavigationStack { ResultsView() }
        }
        .task {
            attemptCounts = AttemptTrackingService.shared.attemptedPasswordCounts(context: modelContext)
        }
        .onChange(of: showResults) { _, newValue in
            if !newValue {
                attemptCounts = AttemptTrackingService.shared.attemptedPasswordCounts(context: modelContext)
            }
        }
        .confirmationDialog(
            "Delete \(viewModel.selectedIDs.count) credential(s)?",
            isPresented: $showBulkDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                let toDelete = credentials.filter { viewModel.selectedIDs.contains($0.id) }
                viewModel.bulkDelete(toDelete, context: modelContext)
                viewModel.isEditMode = false
                viewModel.clearSelection()
            }
        } message: {
            Text("This permanently removes the selected credentials and their stored passwords.")
        }
        .confirmationDialog(
            "Move \(viewModel.selectedIDs.count) credential(s) to the exclude list?",
            isPresented: $showBulkExcludeConfirmation,
            titleVisibility: .visible
        ) {
            Button("Move to Exclude List", role: .destructive) {
                let toMove = credentials.filter { viewModel.selectedIDs.contains($0.id) }
                viewModel.bulkMoveToExcludeList(toMove, context: modelContext)
                viewModel.isEditMode = false
                viewModel.clearSelection()
            }
        } message: {
            Text("Their domains will be skipped for auto-fill and save prompts, and the credentials will be removed.")
        }
        .confirmationDialog(
            "Clear all credentials?",
            isPresented: $showDeleteAllConfirmation,
            titleVisibility: .visible
        ) {
            Button("Clear All", role: .destructive) {
                viewModel.bulkDelete(Array(credentials), context: modelContext)
            }
        } message: {
            Text("This permanently removes every saved credential and its stored password.")
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            if viewModel.isEditMode {
                Button("Done") {
                    viewModel.isEditMode = false
                    viewModel.clearSelection()
                }
            } else {
                Button("Done") { dismiss() }
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button("Select", systemImage: "checkmark.circle") {
                    viewModel.isEditMode = true
                }
                .disabled(filteredCredentials.isEmpty)
                Divider()
                Button("Add Credential", systemImage: "plus") {
                    viewModel.isShowingAddCredential = true
                }
                Button("Import", systemImage: "square.and.arrow.down") {
                    viewModel.isShowingImport = true
                }
                Button("Password Generator", systemImage: "dice") {
                    viewModel.isShowingPasswordGenerator = true
                }
                Divider()
                Button("Excluded Domains", systemImage: "nosign") {
                    viewModel.isShowingExcludedDomains = true
                }
                Button("Clear All Credentials", systemImage: "trash", role: .destructive) {
                    showDeleteAllConfirmation = true
                }
                .disabled(credentials.isEmpty)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }
    }

    // MARK: - Bulk action bar

    private var bulkActionBar: some View {
        HStack(spacing: 16) {
            Button {
                showBulkExcludeConfirmation = true
            } label: {
                Label("Exclude", systemImage: "nosign")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .tint(.orange)
            .disabled(viewModel.selectedIDs.isEmpty)

            Button(role: .destructive) {
                showBulkDeleteConfirmation = true
            } label: {
                Label("Delete", systemImage: "trash")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .disabled(viewModel.selectedIDs.isEmpty)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }

    // MARK: - Rows

    @ViewBuilder
    private func credentialRowButton(_ credential: Credential) -> some View {
        if viewModel.isEditMode {
            Button {
                viewModel.toggleSelection(credential)
            } label: {
                HStack {
                    Image(systemName: viewModel.selectedIDs.contains(credential.id)
                          ? "checkmark.circle.fill"
                          : "circle")
                        .font(.title3)
                        .foregroundStyle(viewModel.selectedIDs.contains(credential.id) ? .cyan : .secondary)
                    credentialRow(credential)
                }
            }
            .buttonStyle(.plain)
        } else {
            Button {
                viewModel.selectedCredential = credential
            } label: {
                credentialRow(credential)
            }
            .buttonStyle(.plain)
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                Button("Delete", systemImage: "trash", role: .destructive) {
                    viewModel.deleteCredential(credential, context: modelContext)
                }
                Button("Exclude", systemImage: "nosign") {
                    viewModel.bulkMoveToExcludeList([credential], context: modelContext)
                }
                .tint(.orange)
            }
        }
    }

    private func credentialRow(_ credential: Credential) -> some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(.linearGradient(
                        colors: [.cyan.opacity(0.3), .blue.opacity(0.3)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ))
                    .frame(width: 40, height: 40)

                Text(String(credential.username.prefix(1)).uppercased())
                    .font(.headline.weight(.bold))
                    .foregroundStyle(.cyan)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(credential.username)
                    .font(.body.weight(.medium))
                    .foregroundStyle(.primary)

                HStack(spacing: 6) {
                    if let attempted = attemptCounts[credential.id], attempted > 0 {
                        let total = max(attempted, KeychainService.shared.getPasswords(for: credential.id).count)
                        Text("\(attempted)/\(total) tried")
                            .font(.system(size: 10, weight: .heavy, design: .rounded))
                            .foregroundStyle(.cyan)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.cyan.opacity(0.15)))
                    }
                    if credential.usageCount > 0 {
                        Text("Used \(credential.usageCount)×")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    if let notes = credential.notes, !notes.isEmpty {
                        Image(systemName: "note.text")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }

            Spacer()

            if !viewModel.isEditMode {
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.quaternary)
            }
        }
    }

    // MARK: - Edit-mode glue

    private var editModeBinding: Binding<EditMode> {
        Binding(
            get: { viewModel.isEditMode ? .active : .inactive },
            set: { viewModel.isEditMode = ($0 == .active) }
        )
    }
}