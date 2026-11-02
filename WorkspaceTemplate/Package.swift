// swift-tools-version: 6.3
// Claudova model workspace. Copied per design project; Claude edits Sources/Model/main.swift.

import PackageDescription

let package = Package(
    name: "Model",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/tomasf/Cadova.git", from: "1.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "Model",
            dependencies: ["Cadova"],
            swiftSettings: [.interoperabilityMode(.Cxx)]
        ),
    ],
    swiftLanguageModes: [.v6]
)
