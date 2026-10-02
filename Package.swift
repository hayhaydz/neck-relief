// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "NeckRelief",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "NeckReliefCore",
            path: "Sources/NeckReliefCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "NeckRelief",
            dependencies: ["NeckReliefCore"],
            path: "Sources/NeckRelief",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "NeckReliefTests",
            dependencies: ["NeckReliefCore"],
            path: "Tests/NeckReliefTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
