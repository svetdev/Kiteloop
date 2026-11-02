import XCTest
@testable import KiteloopCore

/// What a tree implies about its own setup and its own merge gate — read off
/// a listing, so each fixture is a list of paths and the answer is exact.
final class RepoConventionsTests: XCTestCase {

    // MARK: - Setup

    func testALockfileAndAGeneratorEachBecomeOneStepInTheirOwnDirectory() {
        let files = ["apps/web/package-lock.json", "apps/web/src/index.ts",
                     "apps/mobile/ios/project.yml", "README.md"]
        let derived = RepoConventions.setupCommand(files: files)
        XCTAssertEqual(derived.command,
                       "(cd apps/mobile/ios && xcodegen generate) && (cd apps/web && npm ci)")
        XCTAssertEqual(derived.source,
                       "from a project.yml with a gitignored .xcodeproj under apps/mobile/ios, a package-lock under apps/web")
    }

    func testAGeneratorWhoseProjectIsCheckedInDerivesNothing() {
        let files = ["apps/ios/project.yml", "apps/ios/Kiu.xcodeproj/project.pbxproj"]
        XCTAssertNil(RepoConventions.setupCommand(files: files).command)
        let ignored = RepoConventions.setupCommand(files: files, gitignore: "# generated\n*.xcodeproj\n")
        XCTAssertEqual(ignored.command, "(cd apps/ios && xcodegen generate)")
    }

    func testARootLockfileRunsAtTheRootWithoutACd() {
        let derived = RepoConventions.setupCommand(files: ["package-lock.json", "src/a.js"])
        XCTAssertEqual(derived.command, "npm ci")
        XCTAssertEqual(derived.source, "from a package-lock at the root")
    }

    func testTheOtherLockfilesHaveTheirOwnInstalls() {
        XCTAssertEqual(RepoConventions.setupCommand(files: ["web/pnpm-lock.yaml"]).command,
                       "(cd web && pnpm install --frozen-lockfile)")
        XCTAssertEqual(RepoConventions.setupCommand(files: ["web/yarn.lock"]).command,
                       "(cd web && yarn install --frozen-lockfile)")
        XCTAssertEqual(RepoConventions.setupCommand(files: ["ios/Podfile.lock"]).command,
                       "(cd ios && pod install)")
    }

    func testATreeWithNoLockfileAndNoGeneratorDerivesAnEmptySetup() {
        let derived = RepoConventions.setupCommand(files: ["Cargo.lock", "src/main.rs", "scripts/ci.sh"])
        XCTAssertNil(derived.command)
        XCTAssertTrue(derived.source.contains("nothing to set up"), derived.source)
    }

    func testALockfileBuriedDeeperThanTheLimitIsAFixtureNotTheProject() {
        let files = ["a/b/c/d/e/package-lock.json"]
        XCTAssertNil(RepoConventions.setupCommand(files: files).command)
    }

    func testADirectoryTreeIsReadTheSameWayAsAListing() throws {
        let root = try makeTemporaryDirectory(prefix: "repo-conventions")
        let web = root.appending(path: "apps/web")
        try FileManager.default.createDirectory(at: web, withIntermediateDirectories: true)
        try "{}".write(to: web.appending(path: "package-lock.json"), atomically: true, encoding: .utf8)
        let modules = web.appending(path: "node_modules/dep")
        try FileManager.default.createDirectory(at: modules, withIntermediateDirectories: true)
        try "{}".write(to: modules.appending(path: "package-lock.json"), atomically: true, encoding: .utf8)

        let derived = RepoConventions.setupCommand(projectRoot: root)

        XCTAssertEqual(derived.command, "(cd apps/web && npm ci)", "the dependency tree's own lockfiles do not count")
    }

    func testAGitignoreWithABadByteStillMarksTheXcodeprojGenerated() throws {
        let root = try makeTemporaryDirectory(prefix: "repo-conventions")
        try "name: Foo".write(to: root.appending(path: "project.yml"), atomically: true, encoding: .utf8)
        let project = root.appending(path: "Foo.xcodeproj")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try "// pbxproj".write(to: project.appending(path: "project.pbxproj"), atomically: true, encoding: .utf8)
        let gitignore = Data("# cut off ".utf8) + Data([0xFF]) + Data("\n*.xcodeproj\n".utf8)
        try gitignore.write(to: root.appending(path: ".gitignore"))

        let derived = RepoConventions.setupCommand(projectRoot: root)

        XCTAssertEqual(derived.command, "xcodegen generate", "the lines around a bad byte still count")
    }

    // MARK: - Merge verify

    func testTheWidestRuleIsTheMergeVerify() {
        let map = VerifyCoverage.Map(rules: [
            .init(glob: "apps/api/**", command: "./scripts/ci-local.sh rust"),
            .init(glob: "**/*.swift", command: "swift test"),
        ])
        let files = ["apps/api/src/main.rs", "apps/api/Cargo.toml",
                     "Kiteloop/A.swift", "Kiteloop/B.swift", "Kiteloop/C.swift", "README.md"]
        let derived = RepoConventions.mergeVerifyCommand(map: map, files: files)
        XCTAssertEqual(derived.command, "swift test")
        XCTAssertEqual(derived.source, "from verify-map rule `**/*.swift`")
    }

    func testATieGoesToTheLongestCommandAndRunOverridesCommand() {
        let map = VerifyCoverage.Map(rules: [
            .init(glob: "a/**", command: "make a"),
            .init(glob: "b/**", command: "make b && make b-more", run: "make b-fast"),
        ])
        let files = ["a/x", "a/y", "b/x", "b/y"]
        let derived = RepoConventions.mergeVerifyCommand(map: map, files: files)
        XCTAssertEqual(derived.command, "make b-fast", "the rule's `run` spelling is what runs, and its length decides the tie")
    }

    func testNoMapAndNoMatchBothDeriveNothingAndSayWhich() {
        XCTAssertNil(RepoConventions.mergeVerifyCommand(map: .none, files: ["a"]).command)
        XCTAssertEqual(RepoConventions.mergeVerifyCommand(map: .none, files: ["a"]).source, "no verify map")
        let map = VerifyCoverage.Map(rules: [.init(glob: "apps/api/**", command: "cargo test")])
        let derived = RepoConventions.mergeVerifyCommand(map: map, files: ["web/index.ts"])
        XCTAssertNil(derived.command)
        XCTAssertTrue(derived.source.contains("matches anything"), derived.source)
    }
}
