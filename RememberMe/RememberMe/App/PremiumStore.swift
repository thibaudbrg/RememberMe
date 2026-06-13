import Foundation
import Observation
import StoreKit

/// StoreKit 2 wrapper for the single "Premium" entitlement, purchasable as a monthly
/// subscription or a lifetime unlock. Premium gates route refinement and full-history
/// Takeout import (free tier imports only the most recent 14 days).
///
/// The entitlement is enforced entirely on-device — the route proxy authenticates
/// genuine app builds via App Attest but deliberately never learns who paid, so the
/// service stays anonymous.
@MainActor
@Observable
final class PremiumStore {
    static let monthlyID = "app.wave9617.plantain4773.premium.monthly"
    static let lifetimeID = "app.wave9617.plantain4773.premium.lifetime"
    private static let cachedKey = "premium.cached"

    /// True when either product is owned. Starts from the cached last-known value so a
    /// paid user isn't briefly locked out at cold launch (or offline) before
    /// `currentEntitlements` resolves.
    private(set) var isPremium: Bool

    /// Both products, loaded from the App Store. Empty until `load()` succeeds (e.g.
    /// offline) — the paywall shows a retry state in that case.
    private(set) var products: [Product] = []

    private(set) var lastPurchaseError: String?

    /// Free tier imports only the most recent 14 days of a Takeout file; Premium imports
    /// everything. Passed to `AppEnvironment.importTakeout(from:cutoff:)`.
    var importCutoff: Date? {
        isPremium ? nil : Calendar.current.date(byAdding: .day, value: -14, to: .now)
    }

    #if DEBUG
    /// Developer escape hatch for exercising premium flows without a sandbox purchase.
    var debugForcePremium = false {
        didSet { refreshFlag() }
    }
    #endif

    private var entitled = false
    private var updatesTask: Task<Void, Never>?

    init() {
        isPremium = UserDefaults.standard.bool(forKey: Self.cachedKey)
        // Long-lived listener: renewals, revocations, refunds, Ask to Buy approvals,
        // and purchases completed outside the app all land here.
        updatesTask = Task { [weak self] in
            for await update in Transaction.updates {
                if case .verified(let transaction) = update {
                    await transaction.finish()
                }
                await self?.refreshEntitlement()
            }
        }
    }

    /// Loads products and reconciles the entitlement. Safe to call repeatedly.
    func load() async {
        await refreshEntitlement()
        guard products.isEmpty else { return }
        do {
            let loaded = try await Product.products(for: [Self.monthlyID, Self.lifetimeID])
            // Stable order: monthly first, lifetime second.
            products = loaded.sorted { $0.id == Self.monthlyID && $1.id != Self.monthlyID }
        } catch {
            // Offline or App Store hiccup — paywall offers retry via load().
        }
    }

    /// Purchases `product`. Returns true when the entitlement is active afterwards.
    @discardableResult
    func purchase(_ product: Product) async -> Bool {
        lastPurchaseError = nil
        do {
            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                guard case .verified(let transaction) = verification else {
                    lastPurchaseError = "Purchase could not be verified."
                    return false
                }
                await transaction.finish()
                await refreshEntitlement()
                return isPremium
            case .userCancelled:
                return false
            case .pending:
                // Ask to Buy — the updates listener completes it later.
                return false
            @unknown default:
                return false
            }
        } catch {
            lastPurchaseError = error.localizedDescription
            return false
        }
    }

    /// Restores purchases made on another device / reinstall.
    func restore() async {
        lastPurchaseError = nil
        do {
            try await AppStore.sync()
        } catch {
            lastPurchaseError = error.localizedDescription
        }
        await refreshEntitlement()
    }

    private func refreshEntitlement() async {
        var owned = false
        for await entitlement in Transaction.currentEntitlements {
            guard case .verified(let transaction) = entitlement else { continue }
            guard transaction.revocationDate == nil else { continue }
            if transaction.productID == Self.lifetimeID {
                owned = true
            } else if transaction.productID == Self.monthlyID {
                // currentEntitlements only yields active (non-expired) subscriptions.
                owned = true
            }
        }
        entitled = owned
        refreshFlag()
        UserDefaults.standard.set(entitled, forKey: Self.cachedKey)
    }

    private func refreshFlag() {
        #if DEBUG
        isPremium = entitled || debugForcePremium
        #else
        isPremium = entitled
        #endif
    }
}
