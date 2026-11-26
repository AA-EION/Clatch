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

#if os(Linux)
// Linux: the same core, with a GTK 4 / libadwaita app (Sources/ClatchLinux).
// GTK and libadwaita are used through their C API (Sources/CGtk); the oldest
// versions supported are those of Ubuntu 22.04 (GTK 4.6, libadwaita 1.1),
// the oldest system Claude Desktop supports. scripts/build-deb.sh links the
// Swift runtime statically, so the package needs only system libraries.
let package = Package(
    name: "Clatch",
    products: [
        .executable(name: "clatch", targets: ["ClatchLinux"]),
    ],
    targets: [
        .target(name: "ClatchCore"),
        .systemLibrary(name: "CGtk", pkgConfig: "libadwaita-1",
                       providers: [.apt(["libadwaita-1-dev", "libgtk-4-dev"])]),
        .executableTarget(name: "ClatchLinux", dependencies: ["ClatchCore", "CGtk"]),
        .testTarget(name: "ClatchCoreTests", dependencies: ["ClatchCore"]),
    ],
    swiftLanguageModes: [.v6])
#else
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
#endif
