// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Nametag",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "Nametag", path: "Sources/Nametag")
    ]
)
