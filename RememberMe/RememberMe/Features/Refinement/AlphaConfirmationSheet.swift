import SwiftUI

/// One-shot disclosure shown the first time the user flips on alpha mode. Walks through
/// exactly what data leaves the device, and the user has to tap Enable to confirm.
struct AlphaConfirmationSheet: View {
    @Environment(Settings.self) private var settings
    @Environment(\.dismiss) private var dismiss

    /// Bound to the toggle in Settings — if the user cancels we flip it back off.
    @Binding var alphaEnabled: Bool

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("Alpha features are off by default because they're the only part of RememberMe that talks to the network. Read this before enabling.")
                        .font(.callout)
                        .foregroundStyle(.secondary)

                    section(
                        title: "What turning this on enables",
                        body: "A debug-mode screen in Settings where you can replace a recorded trip's GPS samples with the route Apple Maps would have suggested for the same A→B."
                    )

                    section(
                        title: "What leaves your device",
                        body: """
                        • Trip start and end coordinates, rounded to 4 decimals (~11 m).
                        • A coarse transport hint: walking, automobile, or transit.

                        Nothing else: no full GPS track, no place names, no dates, no identity. Apple Maps requests are documented as anonymized and aggregated — the same calls Apple Maps itself makes.
                        """
                    )

                    section(
                        title: "How to disable",
                        body: "Flip this same toggle back off. Trips you already refined stay refined; you can revert each one individually from the alpha screen."
                    )
                }
                .padding(20)
            }
            .navigationTitle("Alpha features")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        alphaEnabled = false
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Enable") {
                        settings.alphaModeAcknowledged = true
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
    }

    @ViewBuilder
    private func section(title: String, body: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.headline)
            Text(body)
                .font(.callout)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
