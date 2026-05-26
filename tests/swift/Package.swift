// swift-tools-version: 6.3
// libsci Swift integration tests

import PackageDescription

let package = Package(
    name: "libsci-tests",
    targets: [
        .executableTarget(
            name: "libsci-tests",
            dependencies: ["Clibsci"]
        ),
        .systemLibrary(
            name: "Clibsci",
            path: "Sources/Clibsci"
        )
    ]
)
