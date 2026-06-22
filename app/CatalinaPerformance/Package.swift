// swift-tools-version:5.2
import PackageDescription

let package = Package(
    name: "CatalinaPerformance",
    platforms: [
        .macOS(.v10_15)
    ],
    products: [
        .executable(name: "CatalinaPerformance", targets: ["CatalinaPerformance"])
    ],
    targets: [
        .target(name: "CatalinaPerformance", dependencies: [])
    ]
)
