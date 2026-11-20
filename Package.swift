// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PrintVault",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .executable(name: "PrintVault", targets: ["PrintVault"])
    ],
    targets: [
        .executableTarget(
            name: "PrintVault",
            path: "Sources/PrintVault",
            exclude: [
                "App/Info.plist",
                "App/PrintVault.entitlements"
            ]
        ),
        .testTarget(
            name: "PrintVaultTests",
            dependencies: ["PrintVault"],
            path: "Tests/PrintVaultTests"
        )
    ]
)
