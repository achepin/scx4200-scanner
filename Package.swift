// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SCX4200Scanner",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "SCX4200Scanner", targets: ["SCX4200Scanner"])],
    targets: [.executableTarget(name: "SCX4200Scanner")]
)
