// swift-tools-version: 6.3
import PackageDescription

let package = Package(
    name: "TextPolish",
    defaultLocalization: "zh-Hans",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "TextPolishApp", targets: ["TextPolishApp"]),
    ],
    dependencies: [
        // 固定到精确版本；升级作为独立改动提交。
        .package(url: "https://github.com/groue/GRDB.swift", exact: "7.11.1"),
    ],
    targets: [
        .target(name: "PolishCore", resources: [.process("Resources/default-polish-template.json"), .process("Resources/providers.json"), .copy("Resources/icons"), .process("Resources/Localization")]),
        .target(name: "PolishStore", dependencies: ["PolishCore", .product(name: "GRDB", package: "GRDB.swift")]),
        .executableTarget(name: "TextPolishApp", dependencies: ["PolishCore", "PolishStore"]),
        .testTarget(name: "PolishCoreTests", dependencies: ["PolishCore"]),
        .testTarget(name: "PolishStoreTests", dependencies: ["PolishStore", "PolishCore"]),
        .testTarget(name: "TextPolishAppTests", dependencies: ["TextPolishApp", "PolishCore", "PolishStore"]),
    ]
)
