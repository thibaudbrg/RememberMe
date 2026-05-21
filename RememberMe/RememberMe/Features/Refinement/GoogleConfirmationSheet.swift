import SwiftUI

/// Disclosure for switching the refinement provider to Google. Distinct from the
/// alpha disclosure (which covers Apple Maps); this one specifically calls out that
/// trip endpoints + your API key go to Google instead of Apple.
struct GoogleConfirmationSheet: View {
    @Environment(Settings.self) private var settings
    @Environment(\.dismiss) private var dismiss

    /// Bound to the provider setting — if the user cancels, we revert to Apple.
    @Binding var selectedProvider: RefinementProvider

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("Switching the refinement provider to Google sends data to Google Maps instead of Apple Maps. The privacy story changes — read this before confirming.")
                        .font(.callout)
                        .foregroundStyle(.secondary)

                    section(
                        title: "Why you'd switch",
                        body: "Apple Maps does not return polylines for public-transit routes via its public API. If you want to refine bus / train / subway trips, you need a provider that does — Google Maps is the most widely-supported option."
                    )

                    section(
                        title: "What leaves your device — to Google",
                        body: """
                        • Trip start and end coordinates, rounded to 4 decimals (~11 m).
                        • A transport mode hint: walking, driving, bicycling, or transit.
                        • Your personal Google Directions API key, on every request.

                        Google receives the request from your device's IP address. Because the key is yours, Google associates these calls with your Google Cloud account — not the RememberMe app or its developer. You can see and rate-limit usage in your Google Cloud console.
                        """
                    )

                    section(
                        title: "What stays on your device",
                        body: "Full GPS samples, place IDs / names / labels, dates, your identity beyond what Google can infer from your API key + IP. Similarity scoring runs locally."
                    )

                    section(
                        title: "Getting an API key",
                        body: "Google Cloud Console → APIs → enable \"Directions API\" → Credentials → create an API key. Paste it in the Alpha section of Settings. Google's free tier covers a few thousand requests per month at the time of writing."
                    )

                    section(
                        title: "How to revert",
                        body: "Switch the provider back to Apple Maps. Previously-refined trips stay refined; you can revert each individually."
                    )
                }
                .padding(20)
            }
            .navigationTitle("Use Google Maps")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        selectedProvider = .apple
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Use Google") {
                        settings.googleRoutingAcknowledged = true
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
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
