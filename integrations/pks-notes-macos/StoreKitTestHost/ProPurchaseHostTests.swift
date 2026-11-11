import StoreKitTest
import StoreKit
import XCTest
@testable import PKSNotesStoreKitHost

@MainActor
final class ProPurchaseHostTests: XCTestCase {
    private var session: SKTestSession!

    override func setUpWithError() throws {
        let bundle = Bundle(for: Self.self)
        let config = try XCTUnwrap(
            bundle.url(forResource: "PKSNotes", withExtension: "storekit"),
            "PKSNotes.storekit must be copied into the hosted test bundle."
        )
        session = try SKTestSession(contentsOf: config)
        session.resetToDefaultState()
        session.disableDialogs = true
        session.clearTransactions()
    }

    override func tearDownWithError() throws {
        session?.clearTransactions()
        session = nil
    }

    func testPurchaseAndRefundDriveVerifiedEntitlement() async throws {
        let store = ProPurchases()
        await store.start()
        XCTAssertFalse(store.unlocked)
        XCTAssertNotNil(store.product)

        await store.purchase()
        await eventually(store, unlocked: true)

        let purchased = try XCTUnwrap(session.allTransactions().first)
        try session.refundTransaction(identifier: purchased.identifier)
        await eventually(store, unlocked: false)
    }

    func testExplicitRestoreKeepsVerifiedPurchaseUnlocked() async throws {
        let purchasingStore = ProPurchases()
        await purchasingStore.start()
        await purchasingStore.purchase()
        await eventually(purchasingStore, unlocked: true)

        let restoredStore = ProPurchases()
        await restoredStore.restore()
        await eventually(restoredStore, unlocked: true)
        XCTAssertEqual(restoredStore.message, "Pro purchase restored.")
    }

    func testAskToBuyStaysLockedUntilApproval() async throws {
        session.askToBuyEnabled = true
        defer { session.askToBuyEnabled = false }

        let store = ProPurchases()
        await store.start()
        XCTAssertNotNil(store.product)

        await store.purchase()
        XCTAssertFalse(store.unlocked)
        XCTAssertEqual(store.message, "Purchase pending approval. Pro will unlock after verification.")

        let pending = try XCTUnwrap(session.allTransactions().first)
        try session.approveAskToBuyTransaction(identifier: pending.identifier)

        await eventually(store, unlocked: true)
    }

    private func eventually(_ store: ProPurchases, unlocked expected: Bool) async {
        for _ in 0..<40 {
            await store.refreshEntitlement()
            if store.unlocked == expected { return }
            try? await Task.sleep(for: .milliseconds(50))
        }
        var evidence: [String] = []
        for await result in Transaction.currentEntitlements {
            switch result {
            case .verified(let transaction):
                evidence.append("verified product=\(transaction.productID) type=\(transaction.productType) revoked=\(transaction.revocationDate != nil)")
            case .unverified(_, let error):
                evidence.append("unverified: \(error.localizedDescription)")
            }
        }
        XCTAssertEqual(store.unlocked, expected,
                       "message=\(store.message ?? "none"); entitlements=\(evidence)")
    }
}
