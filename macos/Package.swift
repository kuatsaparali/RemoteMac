// swift-tools-version: 5.8
import PackageDescription

let package = Package(
    name: "MacRemote",
    platforms: [.macOS(.v13)],
    targets: [.executableTarget(name: "MacRemote")]
)
