import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct ImportCredentialsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @State private var selectedFormat: ImportFormat = .chromeCSV
    @State private var isShowingFilePicker: Bool = false
    @State private var importResult: String?
    @State private var isImporting: Bool = false

    var body: some View {
        Form {
            Section("Format") {
                Picker("Import Format", selection: $selectedFormat) {
                    ForEach(ImportFormat.allCases, id: \.self) { format in
                        Text(format.rawValue).tag(format)
                    }
                }
                .pickerStyle(.segmented)

                Text(selectedFormat.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Button {
                    isShowingFilePicker = true
                } label: {
                    Label("Select CSV File", systemImage: "doc.badge.plus")
                        .frame(maxWidth: .infinity)
                        .font(.headline)
                }
                .buttonStyle(.borderedProminent)
                .disabled(isImporting)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }

            if let result = importResult {
                Section("Result") {
                    Label(result, systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            }

            Section("Instructions") {
                VStack(alignment: .leading, spacing: 8) {
                    instructionRow(number: "1", text: "Export passwords from your browser as CSV")
                    instructionRow(number: "2", text: "Select the matching format above")
                    instructionRow(number: "3", text: "Tap \"Select CSV File\" and choose the export")
                    instructionRow(number: "4", text: "Credentials will be imported to your vault")
                }
            }
        }
        .navigationTitle("Import Credentials")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Done") { dismiss() }
            }
        }
        .fileImporter(
            isPresented: $isShowingFilePicker,
            allowedContentTypes: [UTType.commaSeparatedText, UTType.plainText],
            allowsMultipleSelection: false
        ) { result in
            handleFileImport(result)
        }
    }

    private func instructionRow(number: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(number)
                .font(.caption.bold())
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(.cyan, in: Circle())

            Text(text)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private func handleFileImport(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result, let url = urls.first else { return }
        isImporting = true

        guard url.startAccessingSecurityScopedResource() else {
            importResult = "Could not access file"
            isImporting = false
            return
        }
        defer { url.stopAccessingSecurityScopedResource() }

        do {
            let content = try String(contentsOf: url, encoding: .utf8)
            let imported = CredentialImportService.parseCSV(content, format: selectedFormat)

            var credentials: [(Credential, [String])] = []
            for item in imported {
                let credential = Credential(domain: item.domain, username: item.username, notes: item.notes)
                modelContext.insert(credential)
                credentials.append((credential, item.passwords))
            }

            try modelContext.save()

            var count = 0
            var passwordTotal = 0
            for (credential, passwords) in credentials {
                if KeychainService.shared.savePasswords(passwords, for: credential.id) {
                    count += 1
                    passwordTotal += passwords.count
                }
            }

            importResult = "Imported \(count) credentials (\(passwordTotal) passwords)"
        } catch {
            importResult = "Error reading file: \(error.localizedDescription)"
        }

        isImporting = false
    }
}
