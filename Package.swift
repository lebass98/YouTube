// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MyTube",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(name: "MyTube", path: "Sources/MyTube")
    ]
)
