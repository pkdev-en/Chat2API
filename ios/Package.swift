// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Chat2API_iOS",
    platforms: [.iOS(.v16)],
    products: [
        .executable(name: "Chat2API_iOS", targets: ["Chat2API_iOS"])
    ],
    targets: [
        .executableTarget(
            name: "Chat2API_iOS",
            path: "Chat2API_iOS",
            swiftSettings: [
                .unsafeFlags(["-parse-as-library"])
            ]
        )
    ]
)
