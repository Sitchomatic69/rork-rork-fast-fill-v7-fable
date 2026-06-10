import Foundation
import WebKit

/// Stable, persistent WebKit data-store identifiers for the four Quad-Mode
/// sessions. Using `WKWebsiteDataStore(forIdentifier:)` (iOS 17+) gives each
/// session its own fully isolated cookies, cache, local storage and
/// IndexedDB — sessions cannot see each other.
enum QuadDataStore {
    static let identifiers: [UUID] = [
        UUID(uuidString: "A1A1A1A1-0001-4000-8000-000000000001")!,
        UUID(uuidString: "A2A2A2A2-0002-4000-8000-000000000002")!,
        UUID(uuidString: "A3A3A3A3-0003-4000-8000-000000000003")!,
        UUID(uuidString: "A4A4A4A4-0004-4000-8000-000000000004")!
    ]

    static func identifier(for index: Int) -> UUID {
        identifiers[index % identifiers.count]
    }

    /// Wipes every byte of state for the given Quad session — cookies,
    /// cache, local storage, IndexedDB, service-worker registrations, etc.
    /// Other sessions are untouched.
    static func burn(index: Int) async {
        let store = WKWebsiteDataStore(forIdentifier: identifier(for: index))
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        await store.removeData(ofTypes: types, modifiedSince: Date(timeIntervalSince1970: 0))
    }
}
