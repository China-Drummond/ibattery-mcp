// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ibattery-mcp",
    platforms: [
        .macOS(.v13)
    ],
    dependencies: [
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.12.1")
    ],
    targets: [
        .systemLibrary(
            name: "CLibimobiledevice",
            pkgConfig: "libimobiledevice-1.0",
            providers: [.brew(["libimobiledevice"])]
        ),
        .target(
            name: "IBatteryCore",
            dependencies: [
                .product(name: "MCP", package: "swift-sdk"),
                "CLibimobiledevice"
            ]
        ),
        .executableTarget(
            name: "ibattery-mcp",
            dependencies: ["IBatteryCore"]
        ),
        .executableTarget(
            name: "ibattery-ble-helper",
            dependencies: ["IBatteryCore"]
        ),
        .testTarget(
            name: "IBatteryCoreTests",
            dependencies: ["IBatteryCore"]
        )
    ]
)
