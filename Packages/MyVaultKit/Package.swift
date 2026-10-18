// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MyVaultKit",
    platforms: [.macOS(.v15), .iOS(.v18)],
    products: [
        .library(name: "MyVaultKit", targets: ["MyVaultKit"]),
    ],
    targets: [
        .target(name: "MyVaultKit", swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(
            name: "MyVaultKitTests",
            dependencies: ["MyVaultKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
