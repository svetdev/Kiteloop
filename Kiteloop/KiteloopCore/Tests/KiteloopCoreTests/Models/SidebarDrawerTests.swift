import XCTest
@testable import KiteloopCore

final class SidebarDrawerTests: XCTestCase {
    func testTogglingWithNoneOpenOpensThatDrawer() {
        for drawer in SidebarDrawer.allCases {
            XCTAssertEqual(SidebarDrawer.afterToggling(drawer, from: nil), drawer)
        }
    }

    func testTogglingTheOpenDrawerLeavesNoneOpen() {
        for drawer in SidebarDrawer.allCases {
            XCTAssertNil(SidebarDrawer.afterToggling(drawer, from: drawer))
        }
    }

    func testOpeningAnotherDrawerReplacesTheOpenOne() {
        for open in SidebarDrawer.allCases {
            for toggled in SidebarDrawer.allCases where toggled != open {
                XCTAssertEqual(SidebarDrawer.afterToggling(toggled, from: open), toggled,
                               "opening \(toggled) with \(open) open")
            }
        }
    }

    func testOneSavedFlagOpensThatDrawer() {
        XCTAssertEqual(SidebarDrawer.open(fleet: true, waiting: false), .fleet)
        XCTAssertEqual(SidebarDrawer.open(fleet: false, waiting: true), .waiting)
    }

    func testNoSavedFlagOpensNoDrawer() {
        XCTAssertNil(SidebarDrawer.open(fleet: false, waiting: false))
    }

    func testBothSavedFlagsOpenOnlyTheLeftmost() {
        XCTAssertEqual(SidebarDrawer.open(fleet: true, waiting: true), .fleet)
    }
}
