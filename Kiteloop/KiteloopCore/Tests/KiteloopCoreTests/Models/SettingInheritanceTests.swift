import XCTest
@testable import KiteloopCore

/// The inheritance rule every settings page states: the narrowest explicit
/// value wins, the built-in is the floor, and an empty string is not a value.
final class SettingInheritanceTests: XCTestCase {

    func testBuiltInIsTheFloorWhenNothingIsExplicit() {
        let resolved = SettingInheritance.resolve(builtIn: "fable")
        XCTAssertEqual(resolved, ResolvedSetting(value: "fable", scope: .builtIn))
    }

    func testEachScopeWinsOverTheOneAboveIt() {
        XCTAssertEqual(
            SettingInheritance.resolve(builtIn: "b", app: "a"),
            ResolvedSetting(value: "a", scope: .app))
        XCTAssertEqual(
            SettingInheritance.resolve(builtIn: "b", app: "a", project: "p"),
            ResolvedSetting(value: "p", scope: .project))
        XCTAssertEqual(
            SettingInheritance.resolve(builtIn: "b", app: "a", project: "p", agent: "g"),
            ResolvedSetting(value: "g", scope: .agent))
    }

    func testAGapInTheMiddleIsSkippedNotInherited() {
        // An agent with no explicit value under a project with none falls
        // through to the app, not to the project's absence.
        XCTAssertEqual(
            SettingInheritance.resolve(builtIn: "b", app: "a", project: nil, agent: nil),
            ResolvedSetting(value: "a", scope: .app))
        XCTAssertEqual(
            SettingInheritance.resolve(builtIn: "b", app: nil, project: "p", agent: nil),
            ResolvedSetting(value: "p", scope: .project))
    }

    func testAnEmptyStringIsNotAnExplicitValue() {
        XCTAssertNil(SettingInheritance.present(""))
        XCTAssertNil(SettingInheritance.present(nil))
        XCTAssertEqual(SettingInheritance.present("high"), "high")
        // The forms store "" for "not set"; passed through `present` it must
        // not win the resolution as if somebody had chosen it.
        let resolved = SettingInheritance.resolve(
            builtIn: "b", app: SettingInheritance.present("a"), project: SettingInheritance.present(""))
        XCTAssertEqual(resolved, ResolvedSetting(value: "a", scope: .app))
    }

    func testLabelsNameTheValueAndItsScope() {
        let fromApp = SettingInheritance.resolve(builtIn: "b", app: "a")
        XCTAssertEqual(
            SettingInheritance.defaultLabel(fromApp) { $0.uppercased() },
            "Default (app · A)")
        let builtIn = SettingInheritance.resolve(builtIn: "b")
        XCTAssertEqual(
            SettingInheritance.defaultLabel(builtIn) { $0 },
            "Default (built-in · b)")
        XCTAssertEqual(
            SettingInheritance.inheritedNote(fromApp, prefix: "Project default") { $0 },
            "Project default: a (app)")
    }

    func testNamesSpellTheStoredValuesTheWayThePickersDo() {
        XCTAssertEqual(SettingNames.permissionMode("auto"), "Auto")
        XCTAssertEqual(SettingNames.permissionMode("acceptEdits"), "Accept Edits")
        XCTAssertEqual(SettingNames.permissionMode("default"), "Ask (before edits and commands)",
                       "an attended session asks, so the label says so")
        XCTAssertEqual(SettingNames.permissionMode("dontAsk"), "Don't Ask (refuse what would ask)")
        XCTAssertEqual(SettingNames.permissionMode("bypassPermissions"), "Bypass All")
        XCTAssertEqual(SettingNames.permissionMode("something-new"), "something-new",
                       "an unknown raw value is shown as itself rather than hidden")
        XCTAssertEqual(SettingNames.effort(""), "agent's own")
        XCTAssertEqual(SettingNames.effort("xhigh"), "Extra High")
    }
}
