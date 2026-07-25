// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Chat2API_iOS",
    platforms: [.iOS(.v16)],
    products: [
        .library(name: "Chat2API_iOS", targets: ["Chat2API_iOS"])
    ],
    targets: [
        .target(
            name: "Chat2API_iOS",
            path: "Chat2API_iOS"
        )
    ]
)
