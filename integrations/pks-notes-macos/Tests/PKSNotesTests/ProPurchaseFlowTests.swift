import StoreKitTest
import XCTest
@testable import PKSNotes

@MainActor
final class ProPurchaseFlowTests: XCTestCase {
    func testVerifiedPurchaseAndRefundRevokeAccess() async throws {
        try XCTSkipUnless(
            Bundle.main.bundleIdentifier == "com.moretea.pks.notes",
            "StoreKitTest purchase/refund needs a signed app-host Xcode test; SwiftPM CLI xctest is not entitled."
        )
        let config = try XCTUnwrap(Bundle.module.url(forResource: "PKSNotes", withExtension: "storekit"))
        let session = try SKTestSession(contentsOf: config)
        session.disableDialogs = true
        session.clearTransactions()
        defer { session.clearTransactions() }

        let store = ProPurchases()
        await store.refreshEntitlement()
        XCTAssertFalse(store.unlocked)

        let purchased = try await session.buyProduct(identifier: ProAccess.productID, options: [])
        await store.refreshEntitlement()
        XCTAssertTrue(store.unlocked)

        try session.refundTransaction(identifier: UInt(purchased.id))
        await store.refreshEntitlement()
        XCTAssertFalse(store.unlocked)
    }
}
