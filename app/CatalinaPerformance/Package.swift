// swift-tools-version:5.2
import PackageDescription

let package = Package(
    name: "CatalinaPerformance",
    platforms: [.macOS(.v10_15)],
    products: [
        .executable(name: "CatalinaPerformance", targets: ["CatalinaPerformance"]),
        .executable(name: "CatalinaPerformancePriorityAgent", targets: ["CatalinaPerformancePriorityAgent"])
    ],
    targets: [
        .target(
            name: "CatalinaProcessSupport",
            path: "Sources/CatalinaProcessSupport",
            publicHeadersPath: "include"
        ),
        .target(name: "CatalinaPerformanceCore", dependencies: []),
        .target(name: "CatalinaPerformanceVisualPerformanceCore", dependencies: []),
        .target(
            name: "CatalinaPerformancePriorityCore",
            dependencies: ["CatalinaProcessSupport"]
        ),
        .target(
            name: "CatalinaPerformanceMemoryCore",
            dependencies: [
                "CatalinaPerformancePriorityCore",
                "CatalinaProcessSupport"
            ]
        ),
        .target(
            name: "CatalinaPerformanceDashboardCore",
            dependencies: [
                "CatalinaPerformanceCore",
                "CatalinaPerformancePriorityCore",
                "CatalinaPerformanceMemoryCore",
                "CatalinaProcessSupport"
            ]
        ),
        .target(
            name: "CatalinaPerformanceBackgroundServicesCore",
            dependencies: ["CatalinaPerformancePriorityCore"]
        ),
        .target(
            name: "CatalinaPerformance",
            dependencies: [
                "CatalinaPerformanceCore",
                "CatalinaPerformancePriorityCore",
                "CatalinaPerformanceMemoryCore",
                "CatalinaPerformanceDashboardCore",
                "CatalinaPerformanceBackgroundServicesCore",
                "CatalinaPerformanceVisualPerformanceCore"
            ]
        ),
        .target(
            name: "CatalinaPerformancePriorityAgent",
            dependencies: ["CatalinaPerformancePriorityCore"]
        ),
        .testTarget(
            name: "CatalinaPerformanceTests",
            dependencies: ["CatalinaPerformanceCore", "CatalinaPerformancePriorityCore"]
        ),
        .testTarget(
            name: "CatalinaPerformancePriorityTests",
            dependencies: ["CatalinaPerformancePriorityCore", "CatalinaProcessSupport"]
        ),
        .testTarget(
            name: "CatalinaPerformanceMemoryTests",
            dependencies: [
                "CatalinaPerformanceMemoryCore",
                "CatalinaPerformancePriorityCore",
                "CatalinaProcessSupport"
            ]
        ),
        .testTarget(
            name: "CatalinaPerformanceDashboardTests",
            dependencies: [
                "CatalinaPerformanceDashboardCore",
                "CatalinaPerformancePriorityCore",
                "CatalinaPerformanceMemoryCore",
                "CatalinaProcessSupport"
            ]
        ),
        .testTarget(
            name: "CatalinaPerformanceVisualPerformanceTests",
            dependencies: ["CatalinaPerformanceVisualPerformanceCore"]
        ),
        .testTarget(
            name: "CatalinaPerformanceBackgroundServicesTests",
            dependencies: [
                "CatalinaPerformanceBackgroundServicesCore",
                "CatalinaPerformancePriorityCore"
            ]
        )
    ]
)
