// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "WinLauncherLab",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "winlab", targets: ["WinLab"]),
    ],
    targets: [
        .executableTarget(name: "WinLab"),
        .testTarget(name: "WinLabTests", dependencies: ["WinLab"]),
    ]
)
