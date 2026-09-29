// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MySecretary",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SecretaryCore", targets: ["SecretaryCore"]),
        .executable(name: "MySecretary", targets: ["SecretaryMac"]),
    ],
    targets: [
        .systemLibrary(name: "CSQLite3"),
        .target(name: "SecretaryCore", dependencies: ["CSQLite3"], resources: [.process("Resources")]),
        .executableTarget(name: "SecretaryMac", dependencies: ["SecretaryCore"], resources: [.process("Resources")]),
        .executableTarget(name: "SecretaryCoreChecks", dependencies: ["SecretaryCore"], path: "Tests/SecretaryCoreChecks"),
        .executableTarget(name: "SecretaryAISmoke", dependencies: ["SecretaryCore"], path: "Tests/SecretaryAISmoke"),
    ]
)
