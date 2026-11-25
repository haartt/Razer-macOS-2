// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "MouseR",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "RazerUSB",
            path: "Sources/RazerUSB",
            linkerSettings: [.linkedFramework("IOKit"), .linkedFramework("CoreFoundation")]
        ),
        .executableTarget(
            name: "MouseR",
            dependencies: ["RazerUSB"],
            path: "Sources/MouseR",
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("ApplicationServices"),
            ]
        ),
    ]
)
