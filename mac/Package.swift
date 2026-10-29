// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Kervan",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Kervan", targets: ["Kervan"]),
        .library(name: "KervanKit", targets: ["KervanKit"]),
    ],
    targets: [
        .target(name: "KervanKit"),
        .executableTarget(name: "Kervan", dependencies: ["KervanKit"]),
        .testTarget(name: "KervanKitTests", dependencies: ["KervanKit"]),
    ]
)
