// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "ClaudeDeck",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(path: "SwiftTerm")
    ],
    targets: [
        .executableTarget(
            name: "ClaudeDeck",
            dependencies: [.product(name: "SwiftTerm", package: "SwiftTerm")],
            path: "Sources/ClaudeDeck"
        )
    ]
)
