// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OnePlace",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "OnePlace",
            path: "Sources/OnePlace",
            swiftSettings: [.unsafeFlags(["-parse-as-library"])]
        )
    ]
)
