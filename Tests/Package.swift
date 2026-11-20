// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "BankingTests",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .executable(
            name: "t_banking",
            targets: ["BankingTests"]
        ),
    ],
    dependencies: [
        .package(path: "../Bunq"),
        .package(path: "../PayNL"),
        .package(path: ".."),
    ],
    targets: [
        .executableTarget(
            name: "BankingTests",
            dependencies: [
                .product(name: "Banking", package: "Banking"),
                .product(name: "Bunq", package: "Bunq"),
                .product(name: "PayNL", package: "PayNL"),
            ]
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
