// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "RHRCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "HeartRateKit", targets: ["HeartRateKit"]),
        .library(name: "HeartRateStore", targets: ["HeartRateStore"]),
    ],
    dependencies: [
        // Pinned to an exact release (Package.resolved records its commit hash). 7.9+ needs Swift tools
        // 6.1 (Xcode 16.3+); 7.8.0 builds with every toolchain the README supports. Update
        // deliberately, not automatically: this is the only third-party code in the app.
        .package(url: "https://github.com/groue/GRDB.swift.git", exact: "7.8.0"),
    ],
    targets: [
        // Pure logic: BLE packet parsing, recording, analytics, export. No UIKit / CoreBluetooth.
        .target(name: "HeartRateKit"),
        // SQLite persistence via GRDB.
        .target(
            name: "HeartRateStore",
            dependencies: ["HeartRateKit", .product(name: "GRDB", package: "GRDB.swift")]
        ),
        .testTarget(name: "HeartRateKitTests", dependencies: ["HeartRateKit"]),
        .testTarget(name: "HeartRateStoreTests", dependencies: ["HeartRateStore", "HeartRateKit"]),
    ]
)
