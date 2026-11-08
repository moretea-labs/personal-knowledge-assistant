import StoreKit
import SwiftUI

enum ProAccess {
    static let productID = "com.moretea.pks.notes.pro"
    enum Feature { case mindMap, relationships }
    static func allows(_ feature: Feature, unlocked: Bool) -> Bool { unlocked }
}

@MainActor
final class ProPurchases: ObservableObject {
    @Published private(set) var product: Product?
    @Published private(set) var unlocked = false
    @Published private(set) var busy = false
    @Published private(set) var message: String?
    private var updates: Task<Void, Never>?

    func start() async {
        guard updates == nil else { return }
        updates = Task { [weak self] in
            for await result in Transaction.updates {
                guard let self, !Task.isCancelled else { return }
                if case .verified(let transaction) = result {
                    await self.refreshEntitlement()
                    await transaction.finish()
                } else {
                    self.message = "A transaction could not be verified."
                }
            }
        }
        await refreshEntitlement()
        await loadProduct()
    }

    func loadProduct() async {
        do {
            product = try await Product.products(for: [ProAccess.productID]).first {
                $0.id == ProAccess.productID && $0.type == .nonConsumable
            }
            if product == nil { message = "Pro is not available in this App Store storefront yet." }
            else { message = nil }
        } catch {
            message = "Unable to load Pro from the App Store. Please try again later."
        }
    }

    func refreshEntitlement() async {
        var verified = false
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result,
                  transaction.productID == ProAccess.productID,
                  transaction.productType == .nonConsumable,
                  transaction.revocationDate == nil else { continue }
            verified = true
        }
        unlocked = verified
    }

    func purchase() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        message = nil
        if product == nil { await loadProduct() }
        guard let product else { return }
        do {
            switch try await product.purchase() {
            case .success(.verified(let transaction)):
                await refreshEntitlement()
                await transaction.finish()
                message = unlocked ? "Pro is unlocked." : "Purchase is being processed."
            case .success(.unverified):
                message = "Purchase verification failed. Pro remains locked."
            case .pending:
                message = "Purchase pending approval. Pro will unlock after verification."
            case .userCancelled:
                message = "Purchase cancelled."
            @unknown default:
                message = "Unexpected App Store purchase result."
            }
        } catch {
            message = "Purchase failed. Your notes were not changed."
        }
    }

    func restore() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        message = nil
        do {
            try await AppStore.sync()
            await refreshEntitlement()
            message = unlocked ? "Pro purchase restored." : "No Pro purchase found for this Apple Account."
        } catch {
            message = "Could not restore purchases. Try again when online."
        }
    }
}

struct ProSettingsView: View {
    @EnvironmentObject private var purchases: ProPurchases
    @Environment(\.notesLanguage) private var language

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(language.text("PKS Notes Pro"), systemImage: "point.3.connected.trianglepath.dotted")
                .font(.title2.weight(.semibold))
            Text(language.text("Your Markdown and PDF files always remain yours. No PKS account, subscription or server."))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Divider()
            Label(language.text("Editable mind maps and MindNode interchange"), systemImage: "checkmark.circle")
            Label(language.text("Backlinks and related knowledge"), systemImage: "checkmark.circle")
            if purchases.unlocked {
                Label(language.text("Pro unlocked"), systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green).font(.headline)
            } else {
                Button {
                    Task { await purchases.purchase() }
                } label: {
                    if purchases.busy {
                        ProgressView().controlSize(.small)
                    } else if let product = purchases.product {
                        Text("\(language.text("Unlock Pro")) · \(product.displayPrice)")
                    } else {
                        Text(language.text("Pro not currently available"))
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(purchases.busy || purchases.product == nil)
                .accessibilityIdentifier("pks-purchase-pro")
            }
            if purchases.product == nil && !purchases.unlocked {
                Button(language.text("Retry Loading Pro")) { Task { await purchases.loadProduct() } }
                    .disabled(purchases.busy)
            }
            Button(language.text("Restore Purchases")) { Task { await purchases.restore() } }
                .disabled(purchases.busy)
                .accessibilityIdentifier("pks-restore-purchases")
            if let message = purchases.message {
                Text(language.text(message)).font(.callout).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(width: 440, height: 340)
        .task { await purchases.start() }
    }
}
