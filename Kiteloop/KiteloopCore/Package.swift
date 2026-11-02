// swift-tools-version: 6.0
// The host-less core: code the app runs that needs no app to run it — no
// SwiftUI, no AppKit, no process that has to be Kiteloop.app. Its tests run
// under `swift test`, with no test host, so they are safe to run while the app
// is up and the autopilot's own verify can run them. What moves here is what
// the dependency graph allows: a file whose every reference is already in here.
import PackageDescription

let package = Package(
    name: "KiteloopCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "KiteloopCore", targets: ["KiteloopCore"]),
        // The test helpers both test targets share; the app's test bundle links
        // this product so the helpers exist once.
        .library(name: "KiteloopTestSupport", targets: ["KiteloopTestSupport"]),
    ],
    targets: [
        .target(name: "KiteloopCore", path: "Sources/KiteloopCore"),
        // C, for the one thing Swift has no spelling of: a load-time
        // constructor. It points this process's Kiteloop logs at a temporary
        // directory before any test runs — see Tests/KiteloopTestLogRedirect.
        .target(name: "KiteloopTestLogRedirect", path: "Tests/KiteloopTestLogRedirect"),
        .target(name: "KiteloopTestSupport", dependencies: ["KiteloopCore", "KiteloopTestLogRedirect"],
                path: "Tests/KiteloopTestSupport",
                linkerSettings: [.linkedFramework("XCTest")]),
        .testTarget(name: "KiteloopCoreTests", dependencies: ["KiteloopCore", "KiteloopTestSupport"], path: "Tests/KiteloopCoreTests"),
    ],
    swiftLanguageModes: [.v6]
)
