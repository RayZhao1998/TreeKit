// swift-tools-version: 6.1

import PackageDescription

let package = Package(
  name: "TreeKitDemo",
  platforms: [
    .macOS(.v13)
  ],
  dependencies: [
    .package(name: "TreeKit", path: "..")
  ],
  targets: [
    .executableTarget(
      name: "TreeKitDemo",
      dependencies: [
        .product(name: "TreeKit", package: "TreeKit")
      ],
      resources: [
        .process("Resources")
      ]
    )
  ],
  swiftLanguageModes: [.v6]
)
