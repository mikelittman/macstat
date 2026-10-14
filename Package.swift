// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "macstat",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "macstat", targets: ["macstat"])
    ],
    targets: [
        .executableTarget(
            name: "macstat",
            path: "Sources/macstat"
        )
    ]
)
