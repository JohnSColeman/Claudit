// swift-tools-version: 6.0
import PackageDescription

let v5: [SwiftSetting] = [.swiftLanguageMode(.v5)]

let package = Package(
    name: "Claudit",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Claudit", targets: ["Claudit"]),
        .executable(name: "claudit-report", targets: ["ClauditReport"]),
    ],
    targets: [
        .target(name: "ClauditCore", swiftSettings: v5),
        .executableTarget(name: "Claudit", dependencies: ["ClauditCore"], swiftSettings: v5),
        .executableTarget(name: "ClauditReport", dependencies: ["ClauditCore"], swiftSettings: v5),
        .testTarget(name: "ClauditCoreTests", dependencies: ["ClauditCore"], swiftSettings: v5),
    ]
)
