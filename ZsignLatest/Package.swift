// swift-tools-version: 5.8
import PackageDescription

let package = Package(
    name: "ZsignLatest",
    platforms: [
        .iOS(.v12),
        .macOS(.v10_15),
        .tvOS(.v12),
        .watchOS(.v8),
        .custom("xros", versionString: "1.3")
    ],
    products: [
        .library(name: "zsignc", targets: ["ZsignC"]),
        .library(name: "Zsign", targets: ["Zsign"])
    ],
    dependencies: [
        .package(url: "https://github.com/krzyzanowskim/OpenSSL", exact: "3.3.3001")
    ],
    targets: [
        .target(
            name: "ZsignC",
            dependencies: [
                .product(name: "OpenSSL", package: "OpenSSL")
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
