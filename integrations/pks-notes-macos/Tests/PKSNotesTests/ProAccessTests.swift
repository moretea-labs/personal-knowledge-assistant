import Foundation
import XCTest
@testable import PKSNotes

final class ProAccessTests: XCTestCase {
    func testUnitTestProcessIsNotAnAuthorizedQABundle() {
        XCTAssertFalse(ProAccess.isLocalQA)
    }

    func testFreeTierKeepsAdvancedActionsLocked() {
        XCTAssertFalse(ProAccess.allows(.mindMap, unlocked: false))
        XCTAssertFalse(ProAccess.allows(.relationships, unlocked: false))
    }

    func testVerifiedEntitlementUnlocksOnlyKnownAdvancedActions() {
        XCTAssertTrue(ProAccess.allows(.mindMap, unlocked: true))
        XCTAssertTrue(ProAccess.allows(.relationships, unlocked: true))
    }

    func testStoreKitFixtureUsesTheProductionNonConsumableID() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "PKSNotes", withExtension: "storekit"))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let products = try XCTUnwrap(json["products"] as? [[String: Any]])
        XCTAssertEqual(products.count, 1)
        XCTAssertEqual(products[0]["productID"] as? String, ProAccess.productID)
        XCTAssertEqual(products[0]["type"] as? String, "NonConsumable")
    }
}
