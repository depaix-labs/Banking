// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "Banking",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .library(
            name: "Banking",
            targets: ["Banking"]
        ),
        .executable(
            name: "banking",
            targets: ["BankingCLI"]
        ),
    ],
    dependencies: [
        .package(path: "../Bunq"),
        .package(path: "../PayNL"),
        .package(
            url: "https://github.com/leviouwendijk/Milieu.git",
            branch: "master"
        ),
        .package(
            url: "https://github.com/leviouwendijk/Arguments.git",
            branch: "master"
        ),
    ],
    targets: [
        .target(
            name: "Banking",
            dependencies: [
                .product(name: "Bunq", package: "Bunq"),
                .product(name: "PayNL", package: "PayNL"),
            ],
        ),
        .executableTarget(
            name: "BankingCLI",
            dependencies: [
                "Banking",
                .product(name: "Arguments", package: "Arguments"),
                .product(name: "Bunq", package: "Bunq"),
                .product(name: "Milieu", package: "Milieu"),
                .product(name: "PayNL", package: "PayNL"),
            ],
            path: "Sources/BankingCLI"
        ),
    ],
    swiftLanguageModes: [
        .v6,
    ]
)

for target in package.targets {
    switch target.type {
    case .regular, .executable, .test, .macro:
        var settings = target.swiftSettings ?? []
        settings.append(.treatAllWarnings(as: .error))
        target.swiftSettings = settings

    case .plugin, .system, .binary:
        break

    @unknown default:
        break
    }
}
