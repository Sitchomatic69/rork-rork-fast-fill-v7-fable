import Foundation
import SwiftUI
import WebKit

/// One of the four parallel browser sessions used in Quad Mode. Owns its
/// own WKWebView (with an isolated `WKWebsiteDataStore`) and its own RCR
/// progress so the four sessions can run completely independently.
@Observable
@MainActor
final class QuadSession: Identifiable {
    enum Status: String {
        case idle, navigating, filling, submitting, waiting, burning, success, finished
    }

    let id: String
    let index: Int
    let storeID: UUID

    var url: URL?
    var title: String = ""
    var isLoading: Bool = false
    var estimatedProgress: Double = 0
    var canGoBack: Bool = false
    var canGoForward: Bool = false
    weak var webView: WKWebView?

    // RCR state — per session.
    var rcrRunning: Bool = false
    var rcrStatus: Status = .idle
    var rcrIndex: Int = 0
    var rcrTotal: Int = 0
    var rcrCurrentUsername: String = ""
    var rcrCurrentDomain: String = ""
    var rcrTargetURL: URL?
    var rcrSuccessCount: Int = 0
    var rcrBurnFlash: Int = 0

    var rcrQueueIDs: [String] = []
    /// Snapshot of usernames + password counts captured at run start so the
    /// queue pill stays accurate even if the user edits the vault mid-run.
    var rcrQueueUsernames: [String] = []
    var rcrQueuePasswordCounts: [Int] = []
    /// IDs that have reached a terminal state (success / disabled-burned /
    /// exhausted). Drives the "Completed" section of the queue pill.
    var rcrCompletedIDs: Set<String> = []

    var rcrPasswords: [String] = []
    var rcrPasswordIndex: Int = 0
    var rcrAwaitingNavigation: Bool = false
    /// True while the runner is performing the configured extra submits.
    /// All other RCR actions are paused until this clears.
    var rcrExtraSubmitsInFlight: Bool = false

    init(index: Int) {
        self.index = index
        self.id = "S\(index + 1)"
        self.storeID = QuadDataStore.identifier(for: index)
    }

    var sessionTag: String { id }

    var displayURL: String { url?.absoluteString ?? "" }

    var domain: String {
        guard let host = url?.host(percentEncoded: false)?.lowercased() else { return "" }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}
