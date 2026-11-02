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
        XCTAssertEqual(SidebarDrawer.open(coordinator: true, fleet: false, waiting: false), .coordinator)
        XCTAssertEqual(SidebarDrawer.open(coordinator: false, fleet: true, waiting: false), .fleet)
        XCTAssertEqual(SidebarDrawer.open(coordinator: false, fleet: false, waiting: true), .waiting)
    }

    func testNoSavedFlagOpensNoDrawer() {
        XCTAssertNil(SidebarDrawer.open(coordinator: false, fleet: false, waiting: false))
    }

    func testSeveralSavedFlagsOpenOnlyTheLeftmost() {
        XCTAssertEqual(SidebarDrawer.open(coordinator: true, fleet: true, waiting: false), .coordinator)
        XCTAssertEqual(SidebarDrawer.open(coordinator: true, fleet: false, waiting: true), .coordinator)
        XCTAssertEqual(SidebarDrawer.open(coordinator: false, fleet: true, waiting: true), .fleet)
        XCTAssertEqual(SidebarDrawer.open(coordinator: true, fleet: true, waiting: true), .coordinator)
    }
}
