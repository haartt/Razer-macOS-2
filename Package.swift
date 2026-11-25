// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Mouser",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "RazerUSB",
            path: "Sources/RazerUSB",
            linkerSettings: [.linkedFramework("IOKit"), .linkedFramework("CoreFoundation")]
        ),
        .executableTarget(
            name: "Mouser",
            dependencies: ["RazerUSB"],
            path: "Sources/Mouser",
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("ApplicationServices"),
            ]
        ),
    ]
)
