import SwiftUI

/// Legacy placeholder kept for backward compatibility with early Xcode previews.
/// The real entry point is `RootView`.
struct ContentView: View {
    var body: some View {
        RootView()
    }
}

#Preview {
    ContentView()
        .environment(AppEnvironment.preview())
}
