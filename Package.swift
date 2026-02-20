// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "notsy",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "notsy", targets: ["notsy"])
    ],
    targets: [
        .executableTarget(
            name: "notsy",
            dependencies: [],
            path: "Sources/notsy"
        )
    ]
)
