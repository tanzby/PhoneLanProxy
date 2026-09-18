// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "PhoneLanProxy",
    platforms: [
        .iOS(.v17),
        .macOS(.v13)
    ],
    products: [
        .library(
            name: "PhoneLanProxyCore",
            targets: ["PhoneLanProxyCore"]
        )
    ],
    targets: [
        .target(
            name: "PhoneLanProxyCore",
            path: "Sources/PhoneLanProxyCore"
        ),
        .testTarget(
            name: "PhoneLanProxyCoreTests",
            dependencies: ["PhoneLanProxyCore"],
            path: "Tests/PhoneLanProxyCoreTests"
        )
    ],
    swiftLanguageModes: [.v6]
)
