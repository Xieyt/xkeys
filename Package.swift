// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "xkeys",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "xkeys",
            path: "Sources/xkeys",
            swiftSettings: [
                .unsafeFlags(["-parse-as-library"])
            ]
        )
    ]
)
