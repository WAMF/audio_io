// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
  name: "audio_io",
  platforms: [
    .macOS("10.15")
  ],
  products: [
    // If the plugin name contains "_", replace with "-" for the library name.
    .library(name: "audio-io", targets: ["audio_io"])
  ],
  dependencies: [],
  targets: [
    .target(
      name: "audio_io",
      dependencies: []
    )
  ]
)
