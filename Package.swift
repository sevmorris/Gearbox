// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Gearbox",
    platforms: [.macOS("15.0")],
    targets: [
        .executableTarget(
            name: "Gearbox",
            path: "Sources/Gearbox"
        ),
        .testTarget(
            name: "GearboxTests",
            dependencies: ["Gearbox"],
            path: "Tests/GearboxTests",
            // Define TESTING so GearboxApp.swift can suppress @main in test builds,
            // preventing a conflict with the XCTest runner's own entry point.
            swiftSettings: [.define("TESTING")]
        ),
    ]
)
