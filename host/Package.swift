// swift-tools-version: 6.0

import PackageDescription

let package = Package(
  name: "dvm-core",
  platforms: [
    .macOS(.v15)
  ],
  dependencies: [
    .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.1"),
    .package(url: "https://github.com/mattt/swift-toml.git", from: "1.0.0"),
    .package(url: "https://github.com/grpc/grpc-swift-2.git", from: "2.0.0"),
    .package(url: "https://github.com/grpc/grpc-swift-nio-transport.git", from: "2.0.0"),
    .package(url: "https://github.com/grpc/grpc-swift-protobuf.git", from: "2.0.0"),
    .package(url: "https://github.com/apple/swift-protobuf.git", from: "1.28.0"),
    .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0")
  ],
  targets: [
    .executableTarget(
      name: "dvm-core",
      dependencies: [
        .product(name: "ArgumentParser", package: "swift-argument-parser"),
        .product(name: "TOML", package: "swift-toml"),
        .product(name: "GRPCCore", package: "grpc-swift-2"),
        .product(name: "GRPCNIOTransportHTTP2", package: "grpc-swift-nio-transport"),
        .product(name: "GRPCProtobuf", package: "grpc-swift-protobuf"),
        .product(name: "SwiftProtobuf", package: "swift-protobuf"),
        .product(name: "NIOCore", package: "swift-nio"),
        .product(name: "NIOPosix", package: "swift-nio")
      ],
      path: "Sources",
      swiftSettings: [
        .interoperabilityMode(.Cxx)
      ],
      plugins: [
        .plugin(name: "GRPCProtobufGenerator", package: "grpc-swift-protobuf")
      ]
    ),
    .testTarget(
      name: "dvm-core-tests",
      dependencies: [
        .target(name: "dvm-core")
      ],
      path: "Tests",
      swiftSettings: [
        .interoperabilityMode(.Cxx)
      ]
    )
  ]
)
