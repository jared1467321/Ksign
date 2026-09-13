// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "ASignArchiveKit",
    platforms: [
        .iOS(.v16),
        .macOS(.v13)
    ],
    products: [
        .library(name: "ASignArchiveKit", targets: ["ASignArchiveKit"])
    ],
    dependencies: [
        // Upstream minizip-ng still uses CMake. SideStore's fork tracks upstream
        // and adds the thin SwiftPM manifest needed to build the C library on iOS.
        .package(url: "https://github.com/SideStore/minizip-ng.git", branch: "develop")
    ],
    targets: [
        .target(
            name: "CASignArchive",
            dependencies: [
                .product(name: "minizip-ng", package: "minizip-ng")
            ],
            publicHeadersPath: "include"
        ),
        .target(
            name: "ASignArchiveKit",
            dependencies: ["CASignArchive"]
        )
    ],
    cLanguageStandard: .gnu11
)
