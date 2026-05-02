// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ConjunctEngine",
    platforms: [.macOS(.v13)],
    products: [
        .library(
            name: "ConjunctEngine",
            targets: ["ConjunctEngine"]
        ),
        .executable(
            name: "conjunct-bench",
            targets: ["ConjunctBench"]
        ),
    ],
    dependencies: [
        .package(
            url: "https://github.com/groue/GRDB.swift.git",
            from: "6.0.0"
        ),
    ],
    targets: [
        .target(
            name: "ConjunctEngine",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
        .executableTarget(
            name: "ConjunctBench",
            dependencies: ["ConjunctEngine"]
        ),
        .testTarget(
            name: "ConjunctEngineTests",
            dependencies: ["ConjunctEngine"]
        ),
    ]
)
