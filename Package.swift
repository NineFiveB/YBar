// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "YBar",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "ybar",
            dependencies: ["YBarKit"]
        ),
        .target(
            name: "YBarKit",
            resources: [
                // Copied verbatim and compiled at runtime via makeLibrary(source:) —
                // works without the Xcode metal toolchain (CLT-only machines).
                .copy("Render/Shaders/YBar.metal")
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Metal"),
                .linkedFramework("QuartzCore"),
                .linkedFramework("CoreText"),
                .linkedFramework("IOKit"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("CoreWLAN"),
                .linkedFramework("Network"),
            ]
        ),
        .testTarget(
            name: "YBarKitTests",
            dependencies: ["YBarKit"]
        ),
    ]
)
