import SwiftUI

/// One-time explainer shown the first time the user toggles live tracking on.
/// Tapping "Continue" persists `liveTrackingOnboarded = true` and triggers the
/// iOS authorization prompt via the caller. Tapping "Not now" backs out without
/// flipping the toggle.
struct LiveTrackingOnboardingSheet: View {
    let onContinue: () -> Void
    let onCancel: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    header
                    bullets
                    footnote
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 32)
            }
            .navigationTitle("Live tracking")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Not now", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Continue", action: onContinue)
                        .fontWeight(.semibold)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            ZStack {
                Circle()
                    .fill(.thinMaterial)
                    .frame(width: 64, height: 64)
                Image(systemName: "location.viewfinder")
                    .font(.system(size: 26, weight: .light))
                    .foregroundStyle(.tint)
            }
            Text("Record your trips on this device")
                .font(.title2.weight(.semibold))
            Text("RememberMe will quietly record where you go, classify trips as walking / driving / cycling, and stitch them into your timeline — without needing Google.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var bullets: some View {
        VStack(alignment: .leading, spacing: 18) {
            bullet(
                icon: "lock.shield",
                title: "Stays on your iPhone",
                body: "Locations never leave this device. No analytics, no servers, no Google account."
            )
            bullet(
                icon: "battery.100",
                title: "Designed to be light on battery",
                body: "The app sleeps when you're stationary and only wakes the GPS when you actually move."
            )
            bullet(
                icon: "location.fill",
                title: "Always permission required",
                body: "iOS will ask next. Picking \"Allow Always\" lets the app keep recording when the screen is off."
            )
            bullet(
                icon: "trash",
                title: "Reversible",
                body: "Turn it off here at any time. Recorded data stays on this device; deleting the app removes it all."
            )
        }
    }

    private var footnote: some View {
        Text("Details in the in-app Privacy notes.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private func bullet(icon: String, title: String, body: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 28, alignment: .center)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.semibold))
                Text(body)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

#Preview {
    LiveTrackingOnboardingSheet(onContinue: {}, onCancel: {})
}
