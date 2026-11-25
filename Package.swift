// swift-tools-version:5.9
// NaraChat Livechat SDK, licensed under the Apache License 2.0 (see LICENSE).
import PackageDescription

let package = Package(
    name: "NaraLiveChat",
    platforms: [.iOS(.v15)],
    products: [
        .library(name: "NaraLiveChat", targets: ["NaraLiveChat"]),
    ],
    targets: [
        .target(
            name: "NaraLiveChat",
            path: "Sources/NaraLiveChat"
        ),
        .testTarget(
            name: "NaraLiveChatTests",
            dependencies: ["NaraLiveChat"],
            path: "Tests/NaraLiveChatTests"
        ),
    ]
)
