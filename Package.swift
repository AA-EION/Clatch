// swift-tools-version: 6.2
//
// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Issen Software Group
//
// Clatch: switch Claude Desktop accounts from the menu bar.
//
// Swift 6 language mode (strict data-race checking) with the macOS 26 SDK,
// which provides Liquid Glass. The app deploys back to macOS 11 Big Sur, the
// first release that runs on Apple silicon; every newer API is gated with
// `#available`. scripts/build-app.sh builds arm64 and x86_64 separately and
// merges them into one universal binary.
import PackageDescription

let package = Package(
    name: "Clatch",
    platforms: [.macOS(.v11)],
    products: [
        .executable(name: "Clatch", targets: ["Clatch"]),
    ],
    targets: [
        // Everything that touches the file system and processes, without UI.
        // Kept separate so it can be unit-tested against temporary folders.
        .target(name: "ClatchCore"),

        // The menu bar app (AppKit shell, SwiftUI content).
        .executableTarget(
            name: "Clatch",
            dependencies: ["ClatchCore"],
            linkerSettings: [.linkedFramework("Carbon")]),

        .testTarget(name: "ClatchCoreTests", dependencies: ["ClatchCore"]),
    ],
    swiftLanguageModes: [.v6])
