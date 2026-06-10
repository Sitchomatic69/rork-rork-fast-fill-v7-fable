import SwiftUI

struct ContentView: View {
    @State private var themeManager = ThemeManager.shared

    var body: some View {
        BrowserView()
            .preferredColorScheme(themeManager.preferredColorScheme)
            .onAppear { themeManager.applyToWindow() }
    }
}
