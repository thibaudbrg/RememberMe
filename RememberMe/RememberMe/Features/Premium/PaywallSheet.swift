import StoreKit
import SwiftUI

/// The Premium paywall. Presented when a free user taps a gated action (route
/// refinement, full-history import). Buttons elsewhere stay visible; this sheet is the
/// single place purchases happen.
struct PaywallSheet: View {
    @Environment(PremiumStore.self) private var premium
    @Environment(\.dismiss) private var dismiss

    /// Short context line tailored to the action the user tapped, e.g. why the
    /// refinement they wanted needs Premium. Optional — the generic pitch stands alone.
    var contextLine: String?

    @State private var purchasing = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    header
                    bullets
                    priceButtons
                    restoreAndLegal
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 32)
            }
            .navigationTitle("Premium")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Not now") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .onChange(of: premium.isPremium) { _, owned in
            if owned { dismiss() }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            ZStack {
                Circle()
                    .fill(.thinMaterial)
                    .frame(width: 64, height: 64)
                Image(systemName: "sparkles")
                    .font(.system(size: 26, weight: .light))
                    .foregroundStyle(.tint)
            }
            Text("Unlock your whole history")
                .font(.title2.weight(.semibold))
            Text(contextLine ?? "One unlock for everything RememberMe can do with your past.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var bullets: some View {
        VStack(alignment: .leading, spacing: 18) {
            bullet(
                icon: "point.topleft.down.curvedto.point.bottomright.up",
                title: "Refine your routes",
                body: "Snap noisy GPS traces to real roads, rails and paths — one trip, a whole day, or your entire history at once."
            )
            bullet(
                icon: "clock.arrow.circlepath",
                title: "Import your full history",
                body: "Free imports cover the last 14 days of your Google Maps timeline. Premium imports all of it — years back."
            )
            bullet(
                icon: "hand.raised",
                title: "Private by design",
                body: "Refining sends only a trip's start and end points (rounded to ~11 m) to RememberMe's routing service, then on to Google. No identity, no full track, no dates."
            )
        }
    }

    private var priceButtons: some View {
        VStack(spacing: 12) {
            if premium.products.isEmpty {
                HStack {
                    Spacer()
                    VStack(spacing: 8) {
                        Text("Couldn't load prices.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Button("Try again") {
                            Task { await premium.load() }
                        }
                        .font(.footnote.weight(.semibold))
                    }
                    Spacer()
                }
                .padding(.vertical, 12)
            } else {
                ForEach(premium.products, id: \.id) { product in
                    Button {
                        purchasing = true
                        Task {
                            await premium.purchase(product)
                            purchasing = false
                        }
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(label(for: product))
                                    .font(.callout.weight(.semibold))
                                Text(detail(for: product))
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(product.displayPrice)
                                .font(.callout.weight(.semibold))
                                .foregroundStyle(.tint)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .contentShape(RoundedRectangle(cornerRadius: 14))
                    }
                    .buttonStyle(.plain)
                    .liquidGlassPanel(in: RoundedRectangle(cornerRadius: 14))
                }
            }
            if let error = premium.lastPurchaseError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .disabled(purchasing)
        .overlay {
            if purchasing { ProgressView() }
        }
    }

    private var restoreAndLegal: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button("Restore purchases") {
                Task { await premium.restore() }
            }
            .font(.footnote.weight(.semibold))
            HStack(spacing: 12) {
                Link("Terms of Use", destination: URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!)
                Link("Privacy Policy", destination: URL(string: "https://github.com/tibo/RememberMe/blob/main/PRIVACY.md")!)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            Text("Monthly renews automatically until cancelled in Settings. Lifetime is a one-time purchase.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func label(for product: Product) -> String {
        product.id == PremiumStore.lifetimeID ? "Lifetime" : "Monthly"
    }

    private func detail(for product: Product) -> String {
        product.id == PremiumStore.lifetimeID
            ? "Pay once, keep it forever."
            : "Cancel anytime."
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
    PaywallSheet()
        .environment(PremiumStore())
}
