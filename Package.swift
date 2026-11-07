// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "Sextant",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "SextantApp", targets: ["SextantApp"]),
        .executable(name: "sextant", targets: ["sextant"]),
    ],
    dependencies: [
        .package(url: "https://github.com/ChimeHQ/SwiftTreeSitter", from: "0.25.0"),
    ],
    targets: [
        .target(name: "SextantCore", dependencies: [
            .product(name: "SwiftTreeSitter", package: "SwiftTreeSitter"),
        ]),
        .executableTarget(name: "SextantApp", dependencies: ["SextantCore"]),
        .executableTarget(name: "sextant", dependencies: ["SextantCore"]),
        .testTarget(name: "SextantCoreTests", dependencies: ["SextantCore"]),
    ]
)
