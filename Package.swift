// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "cliPets",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "petd",
            path: "Sources/petd"
        ),
        .executableTarget(
            name: "clipets",
            path: "Sources/clipets"
        ),
        .executableTarget(
            name: "petdemo",
            path: "Sources/petdemo"
        ),
    ]
)
