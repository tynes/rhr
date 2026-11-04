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
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
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
