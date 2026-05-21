import SwiftUI

struct ContentView: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "map.fill")
                .font(.system(size: 48, weight: .semibold))
                .foregroundStyle(.tint)
            Text("RememberMe")
                .font(.title2.weight(.semibold))
            Text("Scaffold only — map and timeline arrive in the next round.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
    }
}

#Preview {
    ContentView()
}
