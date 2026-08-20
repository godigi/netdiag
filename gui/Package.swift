// swift-tools-version: 5.9
//
// netdiag.app — the menu-bar client for the netdiag CLI.
//
// SwiftPM rather than an Xcode project, because this machine has only the
// Command Line Tools. SwiftUI.framework and Charts.framework are both
// present in the CLT SDK, so the build works; what is missing is previews,
// a project file, and automatic bundling. `make -C gui run` stands in for
// the first, this file for the second, and gui/Makefile for the third.
//
// Language mode is Swift 5, not 6. The concurrency discipline the plan
// calls for is followed regardless — stores are @MainActor, runners are
// plain async functions returning values, and nothing shares mutable state
// across actors — but adopting strict concurrency wholesale while also
// having no previews to iterate against would trade a real day of build
// errors for a hazard this code's shape already avoids.

import PackageDescription

let package = Package(
    name: "NetdiagGUI",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "NetdiagGUI",
            path: "Sources/NetdiagGUI"
        ),
        .testTarget(
            name: "NetdiagGUITests",
            dependencies: ["NetdiagGUI"],
            path: "Tests/NetdiagGUITests",
            // The CLT-only toolchain (no Xcode.app — see this file's
            // header) ships Swift Testing's Testing.framework under
            // Library/Developer/Frameworks, a path SwiftPM does not search
            // by default. Without this flag `import Testing` fails with
            // "no such module 'Testing'" and `swift test` cannot run at all
            // — which would leave the GUI's only repeatable verification
            // path (the one this target exists to provide) unrunnable on
            // the very machine it was created on. XCTest is not an
            // alternative here: the CLT does not ship it for macOS, so Swift
            // Testing is the only framework available here. The path is
            // harmless on an Xcode machine: a `-F` to a directory that does
            // not exist is ignored, and one that does exist (CLT installed
            // alongside Xcode is common) just adds a valid search location
            // without displacing the default Xcode discovery.
            swiftSettings: [.unsafeFlags(["-F", "/Library/Developer/CommandLineTools/Library/Developer/Frameworks"])],
            linkerSettings: [.unsafeFlags(["-F", "/Library/Developer/CommandLineTools/Library/Developer/Frameworks"])]
        )
    ]
)
