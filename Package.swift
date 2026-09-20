// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "aii",
    platforms: [.macOS("26.0")],
    dependencies: [
        .package(
            url: "https://github.com/apple/swift-argument-parser",
            from: "1.3.0"
        )
    ],
    targets: [
        .executableTarget(
            name: "aii",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser")
            ]
        ),
        .testTarget(
            name: "aiiTests",
            dependencies: ["aii"]
        )
    ]
)
