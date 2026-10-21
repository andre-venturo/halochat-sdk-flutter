// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "halochat_flutter",
    platforms: [
        .iOS("15.0")
    ],
    products: [
        .library(name: "halochat-flutter", targets: ["halochat_flutter"])
    ],
    dependencies: [
        .package(name: "FlutterFramework", path: "../FlutterFramework"),
        .package(url: "https://github.com/afgventura/halochat-ios.git", from: "0.3.0"),
    ],
    targets: [
        .target(
            name: "halochat_flutter",
            dependencies: [
                .product(name: "FlutterFramework", package: "FlutterFramework"),
                // Core product only (not HaloChatUI): the app draws its own chat screen.
                .product(name: "HaloChat", package: "halochat-ios"),
            ]
        )
    ]
)
