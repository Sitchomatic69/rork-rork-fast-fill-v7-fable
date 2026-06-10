import SwiftUI
import SwiftData

struct CredentialDetailView: View {
    let credential: Credential
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @State private var passwords: [String] = []
    @State private var visibleIndices: Set<Int> = []
    @State private var isEditing: Bool = false
    @State private var editUsername: String = ""
    @State private var editPasswords: [String] = []
    @State private var editNotes: String = ""
    @State private var showDeleteConfirmation: Bool = false
    @State private var showExcludeConfirmation: Bool = false

    var body: some View {
        Form {
            Section("Account") {
                LabeledContent("Domain", value: credential.domain)

                if isEditing {
                    TextField("Username", text: $editUsername)
                } else {
                    HStack {
                        LabeledContent("Username", value: credential.username)
                        Spacer()
                        Button("Copy", systemImage: "doc.on.doc") {
                            UIPasteboard.general.string = credential.username
                        }
                        .labelStyle(.iconOnly)
                        .font(.caption)
                    }
                }
            }

            Section {
                if isEditing {
                    ForEach(editPasswords.indices, id: \.self) { index in
                        HStack {
                            SecureField(
                                index == 0 ? "Primary password" : "Password \(index + 1)",
                                text: $editPasswords[index]
                            )
                            if editPasswords.count > 1 {
                                Button {
                                    editPasswords.remove(at: index)
                                } label: {
                                    Image(systemName: "minus.circle.fill")
                                        .foregroundStyle(.red)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .onMove { from, to in
                        editPasswords.move(fromOffsets: from, toOffset: to)
                    }
                    Button {
                        editPasswords.append("")
                    } label: {
                        Label("Add another password", systemImage: "plus.circle.fill")
                    }
                    .foregroundStyle(.cyan)
                } else {
                    if passwords.isEmpty {
                        Text("No password stored")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(passwords.indices, id: \.self) { index in
                            passwordRow(index: index)
                        }
                    }
                }
            } header: {
                HStack {
                    Text("Passwords")
                    if !isEditing && passwords.count > 1 {
                        Text("· \(passwords.count)")
                            .foregroundStyle(.secondary)
                    }
                }
            } footer: {
                if !isEditing && passwords.count > 1 {
                    Text("RCR tries each password in order if a login is rejected.")
                }
            }

            Section("Notes") {
                if isEditing {
                    TextField("Notes", text: $editNotes, axis: .vertical)
                        .lineLimit(3...6)
                } else {
                    if let notes = credential.notes, !notes.isEmpty {
                        Text(notes)
                            .font(.body)
                    } else {
                        Text("No notes")
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("Info") {
                LabeledContent("Created", value: credential.createdAt.formatted(date: .abbreviated, time: .shortened))
                LabeledContent("Updated", value: credential.updatedAt.formatted(date: .abbreviated, time: .shortened))
                if let lastUsed = credential.lastUsedAt {
                    LabeledContent("Last Used", value: lastUsed.formatted(date: .abbreviated, time: .shortened))
                }
                LabeledContent("Times Used", value: "\(credential.usageCount)")
            }

            if !isEditing {
                Section {
                    Button("Move to Exclude List", systemImage: "nosign") {
                        showExcludeConfirmation = true
                    }
                    .tint(.orange)

                    Button("Delete Credential", role: .destructive) {
                        showDeleteConfirmation = true
                    }
                }
            }
        }
        .navigationTitle(credential.displayDomain)
        .navigationBarTitleDisplayMode(.inline)
        .environment(\.editMode, .constant(isEditing ? .active : .inactive))
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button(isEditing ? "Cancel" : "Done") {
                    if isEditing {
                        isEditing = false
                    } else {
                        dismiss()
                    }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button(isEditing ? "Save" : "Edit") {
                    if isEditing {
                        saveChanges()
                    } else {
                        startEditing()
                    }
                }
            }
        }
        .task {
            passwords = KeychainService.shared.getPasswords(for: credential.id)
        }
        .confirmationDialog("Delete Credential?", isPresented: $showDeleteConfirmation, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                KeychainService.shared.deletePassword(for: credential.id)
                modelContext.delete(credential)
                dismiss()
            }
        } message: {
            Text("This will permanently delete the credential for \(credential.username)")
        }
        .confirmationDialog(
            "Move to Exclude List?",
            isPresented: $showExcludeConfirmation,
            titleVisibility: .visible
        ) {
            Button("Move to Exclude List", role: .destructive) {
                moveToExcludeList()
                dismiss()
            }
        } message: {
            Text("\(credential.displayDomain) will be skipped for auto-fill and save prompts, and this credential will be removed.")
        }
    }

    @ViewBuilder
    private func passwordRow(index: Int) -> some View {
        let visible = visibleIndices.contains(index)
        let value = passwords[index]
        HStack(spacing: 8) {
            Text("\(index + 1)")
                .font(.caption.monospacedDigit().weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 18, alignment: .leading)

            if visible {
                Text(value)
                    .font(.body.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else {
                Text(String(repeating: "•", count: max(8, min(value.count, 14))))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                if visible {
                    visibleIndices.remove(index)
                } else {
                    visibleIndices.insert(index)
                }
            } label: {
                Image(systemName: visible ? "eye.slash" : "eye")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)

            Button {
                UIPasteboard.general.string = value
            } label: {
                Image(systemName: "doc.on.doc")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
    }

    private func startEditing() {
        editUsername = credential.username
        editPasswords = passwords.isEmpty ? [""] : passwords
        editNotes = credential.notes ?? ""
        isEditing = true
    }

    private func saveChanges() {
        credential.username = editUsername
        credential.notes = editNotes.isEmpty ? nil : editNotes
        credential.updatedAt = Date()
        let cleaned = editPasswords.filter { !$0.isEmpty }
        if cleaned != passwords {
            _ = KeychainService.shared.savePasswords(cleaned, for: credential.id)
            passwords = cleaned
            visibleIndices.removeAll()
        }
        isEditing = false
    }

    private func moveToExcludeList() {
        let domain = ExcludedDomain.canonicalize(credential.domain)
        guard !domain.isEmpty else {
            KeychainService.shared.deletePassword(for: credential.id)
            modelContext.delete(credential)
            return
        }
        let descriptor = FetchDescriptor<ExcludedDomain>(
            predicate: #Predicate<ExcludedDomain> { $0.domain == domain }
        )
        if (try? modelContext.fetch(descriptor).first) == nil {
            modelContext.insert(ExcludedDomain(domain: domain))
        }
        KeychainService.shared.deletePassword(for: credential.id)
        modelContext.delete(credential)
    }
}
