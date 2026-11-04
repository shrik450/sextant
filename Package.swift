// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "Revue",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "RevueApp", targets: ["RevueApp"]),
        .executable(name: "revue", targets: ["revue"]),
    ],
    dependencies: [
        .package(url: "https://github.com/ChimeHQ/SwiftTreeSitter", from: "0.25.0"),
    ],
    targets: [
        .target(name: "RevueCore", dependencies: [
            .product(name: "SwiftTreeSitter", package: "SwiftTreeSitter"),
        ]),
        .executableTarget(name: "RevueApp", dependencies: ["RevueCore"]),
        .executableTarget(name: "revue"),
        .testTarget(name: "RevueCoreTests", dependencies: ["RevueCore"]),
    ]
)
