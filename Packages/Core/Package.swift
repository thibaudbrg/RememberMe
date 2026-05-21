// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Core",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "Core", targets: ["Core"]),
    ],
    dependencies: [
        // Thin Swift wrapper over the P-H-C reference Argon2 C library. Used for the
        // encrypted-export passphrase KDF (argon2id). Pinned to a commit on main because
        // the wrapper transitively depends on P-H-C's argon2 repo via .branch("master"),
        // which SPM refuses to combine with a stable-version dep.
        .package(
            url: "https://github.com/tmthecoder/Argon2Swift.git",
            revision: "53543623fefe68461b7eeea03d7f96677c2fd76d"
        ),
    ],
    targets: [
        .target(
            name: "Core",
            dependencies: [
                .product(name: "Argon2Swift", package: "Argon2Swift"),
            ],
            path: "Sources/Core"
        ),
        .testTarget(
            name: "CoreTests",
            dependencies: ["Core"],
            path: "Tests/CoreTests",
            resources: [.copy("Resources")]
        ),
    ]
)
