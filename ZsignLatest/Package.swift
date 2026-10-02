// swift-tools-version: 5.8
import PackageDescription

let package = Package(
    name: "ZsignLatest",
    platforms: [
        .iOS(.v14),
        .macOS(.v11),
        .tvOS(.v14),
        .watchOS(.v8),
        .custom("xros", versionString: "1.3")
    ],
    products: [
        .library(name: "zsignc", targets: ["ZsignC"]),
        .library(name: "Zsign", targets: ["Zsign"])
    ],
    dependencies: [
        .package(url: "https://github.com/krzyzanowskim/OpenSSL", exact: "3.3.3001"),
        .package(url: "https://github.com/SideStore/minizip-ng.git", branch: "develop")
    ],
    targets: [
        .target(
            name: "ZsignC",
            dependencies: [
                .product(name: "OpenSSL", package: "OpenSSL"),
                .product(name: "minizip-ng", package: "minizip-ng")
            ],
            path: "Sources/ZsignC",
            sources: [
                "ZsignBridge.mm",
                "Core/archo.cpp",
                "Core/bundle.cpp",
                "Core/macho.cpp",
                "Core/openssl.cpp",
                "Core/signing.cpp",
                "Core/common/fs.cpp",
                "Core/common/json.cpp",
                "Core/common/log.cpp",
                "Core/common/sha.cpp",
                "Core/common/timer.cpp",
                "Core/common/util.cpp"
            ],
            publicHeadersPath: "include",
            cxxSettings: [
                .headerSearchPath("Core"),
                .headerSearchPath("Core/common"),
                .unsafeFlags(["-std=c++17"])
            ],
            linkerSettings: [
                .linkedFramework("OpenSSL")
            ]
        ),
        .target(
            name: "Zsign",
            dependencies: ["ZsignC"],
            path: "Sources/Zsign"
        )
    ],
    cxxLanguageStandard: .cxx17
)
