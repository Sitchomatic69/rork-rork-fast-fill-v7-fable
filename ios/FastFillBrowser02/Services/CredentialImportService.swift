import Foundation
import SwiftData
import UniformTypeIdentifiers

nonisolated struct ImportedCredential: Sendable {
    let domain: String
    let username: String
    /// One or more passwords for this credential. The first entry is the
    /// primary password used by single-shot autofill; RCR will try the rest
    /// in order if the primary is rejected.
    let passwords: [String]
    let notes: String?

    /// Convenience accessor for legacy single-password code paths.
    var password: String { passwords.first ?? "" }
}

nonisolated enum ImportFormat: String, CaseIterable, Sendable {
    case chromeCSV = "Chrome CSV"
    case firefoxCSV = "Firefox CSV"
    case genericCSV = "Generic CSV"
    case multiPasswordCSV = "Multi-Password CSV"

    var description: String {
        switch self {
        case .chromeCSV: return "Export from Chrome: Settings → Passwords → Export"
        case .firefoxCSV: return "Export from Firefox: Settings → Logins → Export"
        case .genericCSV: return "CSV with columns: url, username, password"
        case .multiPasswordCSV:
            return "CSV with: email, password1, password2, … — multiple passwords per email on the same row."
        }
    }
}

struct CredentialImportService {
    static func parseCSV(_ content: String, format: ImportFormat) -> [ImportedCredential] {
        if format == .multiPasswordCSV {
            return parseMultiPasswordCSV(content)
        }

        let lines = content.components(separatedBy: .newlines).filter { !$0.isEmpty }
        guard lines.count > 1 else { return [] }

        var results: [ImportedCredential] = []

        for line in lines.dropFirst() {
            let fields = parseCSVLine(line)
            guard fields.count >= 3 else { continue }

            let (urlField, userField, passField) = fieldIndices(for: format, fields: fields)
            guard let url = urlField, let user = userField, let pass = passField else { continue }
            guard !user.isEmpty, !pass.isEmpty else { continue }

            let domain = extractDomain(from: url)
            guard !domain.isEmpty else { continue }

            results.append(ImportedCredential(
                domain: domain,
                username: user,
                passwords: [pass],
                notes: nil
            ))
        }

        return results
    }

    /// Parse the wide "email, password1, password2, …" format. The first
    /// column is the email (also used as the username); every remaining
    /// non-empty column on the row is a saved password for that email.
    /// The credential's `domain` is taken from the email's domain part so
    /// the vault still groups by provider, but RCR treats credentials as
    /// global so this only affects vault grouping/sort.
    static func parseMultiPasswordCSV(_ content: String) -> [ImportedCredential] {
        let lines = content.components(separatedBy: .newlines).filter { !$0.isEmpty }
        guard !lines.isEmpty else { return [] }

        // Detect header: if the first column is literally "email" we drop
        // the first row. Otherwise treat every row as data.
        let firstFields = parseCSVLine(lines[0])
        let dataLines: ArraySlice<String>
        if let first = firstFields.first?.lowercased(), first == "email" || first == "username" {
            dataLines = lines.dropFirst()
        } else {
            dataLines = lines[lines.indices]
        }

        // Coalesce duplicate emails: if the same email appears on multiple
        // rows, merge their passwords into one credential (deduped, order
        // preserved).
        var orderedEmails: [String] = []
        var bucket: [String: [String]] = [:]

        for line in dataLines {
            let fields = parseCSVLine(line)
            guard let emailRaw = fields.first else { continue }
            let email = emailRaw.trimmingCharacters(in: .whitespaces)
            guard !email.isEmpty, email.contains("@") else { continue }

            let passwords = fields.dropFirst().map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }

            if bucket[email] == nil {
                orderedEmails.append(email)
                bucket[email] = []
            }
            for pass in passwords where !(bucket[email]?.contains(pass) ?? false) {
                bucket[email, default: []].append(pass)
            }
        }

        return orderedEmails.compactMap { email in
            let passwords = bucket[email] ?? []
            guard !passwords.isEmpty else { return nil }
            let domain = email.split(separator: "@").last.map(String.init)?.lowercased() ?? ""
            guard !domain.isEmpty else { return nil }
            return ImportedCredential(
                domain: domain,
                username: email,
                passwords: passwords,
                notes: nil
            )
        }
    }

    private static func fieldIndices(
        for format: ImportFormat,
        fields: [String]
    ) -> (String?, String?, String?) {
        switch format {
        case .chromeCSV:
            guard fields.count >= 4 else { return (nil, nil, nil) }
            return (fields[1], fields[2], fields[3])
        case .firefoxCSV:
            guard fields.count >= 3 else { return (nil, nil, nil) }
            return (fields[0], fields[1], fields[2])
        case .genericCSV:
            return (fields[0], fields[1], fields[2])
        case .multiPasswordCSV:
            return (nil, nil, nil) // handled by parseMultiPasswordCSV
        }
    }

    static func extractDomain(from urlString: String) -> String {
        return ExcludedDomain.canonicalize(urlString)
    }

    private static func parseCSVLine(_ line: String) -> [String] {
        var fields: [String] = []
        var current = ""
        var inQuotes = false

        for char in line {
            if char == "\"" {
                inQuotes.toggle()
            } else if char == "," && !inQuotes {
                fields.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(char)
            }
        }
        fields.append(current.trimmingCharacters(in: .whitespaces))

        return fields
    }
}
