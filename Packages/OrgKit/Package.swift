// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OrgKit",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "OrgKit", targets: ["OrgKit"]),
    ],
    targets: [
        .target(name: "OrgKit"),
        .testTarget(name: "OrgKitTests", dependencies: ["OrgKit"]),
    ]
)
