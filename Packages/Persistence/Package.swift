// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Persistence",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "Persistence", targets: ["Persistence"]),
    ],
    dependencies: [
        .package(path: "../Core"),
        .package(url: "https://github.com/sqlcipher/sqlcipher.swift", from: "4.10.0"),
    ],
    targets: [
        .target(
            name: "Persistence",
            dependencies: [
                .product(name: "Core", package: "Core"),
                .product(name: "SQLCipher", package: "sqlcipher.swift"),
            ],
            path: "Sources/Persistence"
        ),
        .testTarget(
            name: "PersistenceTests",
            dependencies: ["Persistence"],
            path: "Tests/PersistenceTests"
        ),
    ]
)
