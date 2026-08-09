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
    targets: [
        .target(name: "TreeKit"),
        .testTarget(name: "TreeKitTests", dependencies: ["TreeKit"])
    ],
    swiftLanguageModes: [.v6]
)
