// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DuckyAccess",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "DuckyAccess", targets: ["DuckyAccess"])
    ],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", revision: "71242fa6df36ed956ee347690df4428a736eb761")
    ],
    targets: [
        .executableTarget(
            name: "DuckyAccess",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio")
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("CoreML"),
                .linkedFramework("IOKit"),
                .linkedFramework("WebKit"),
                .linkedFramework("ServiceManagement")
            ]
        ),
        .testTarget(name: "DuckyAccessTests", dependencies: ["DuckyAccess"]),
        .executableTarget(
            name: "ParakeetProbe",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio")
            ],
            linkerSettings: [
                .linkedFramework("AVFoundation")
            ]
        )
    ],
    swiftLanguageModes: [.v5]
)
