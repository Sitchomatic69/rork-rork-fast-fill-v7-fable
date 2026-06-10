import SwiftUI
import SwiftData

@main
struct FastFillBrowser02App: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(for: [
            Credential.self,
            SiteSetting.self,
            BrowsingHistoryEntry.self,
            Bookmark.self,
            ExcludedDomain.self,
            AttemptRecord.self
        ])
    }
}
