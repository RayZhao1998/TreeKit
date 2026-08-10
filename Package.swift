// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "TreeKit",
    platforms: [
        .macOS(.v13),
        .iOS(.v16)
    ],
    products: [
        .library(name: "TreeKit", targets: ["TreeKit"])
    ],
    dependencies: [
        .package(
            url: "https://github.com/swiftlang/swift-docc-plugin",
            from: "1.5.0"
        )
    ],
    targets: [
        .target(
            name: "TreeKit",
            resources: [.process("Resources")]
        ),
        .testTarget(name: "TreeKitTests", dependencies: ["TreeKit"])
    ],
    swiftLanguageModes: [.v6]
)
