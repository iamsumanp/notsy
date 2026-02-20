// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "notebar",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "notebar", targets: ["notebar"])
    ],
    targets: [
        .executableTarget(
            name: "notebar",
            dependencies: [],
            path: "Sources/notebar"
        )
    ]
)
