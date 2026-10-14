// swift-tools-version: 6.0

import PackageDescription

let package = Package(
  name: "Transcribe",
  platforms: [
    .macOS(.v13)
  ],
  products: [
    .executable(name: "transcribe", targets: ["Transcribe"])
  ],
  targets: [
    .executableTarget(name: "Transcribe"),
    .testTarget(
      name: "TranscribeTests",
      dependencies: ["Transcribe"]
    ),
  ]
)
