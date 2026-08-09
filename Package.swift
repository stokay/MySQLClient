// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MySQLMacClient",
    // Required the moment a target ships a localized resource — SwiftPM
    // fails the manifest outright without it. "en" matches the String
    // Catalog's own source language and Info.plist's
    // CFBundleDevelopmentRegion.
    defaultLocalization: "en",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .executable(name: "MySQLMacClient", targets: ["MySQLMacClient"])
    ],
    dependencies: [
        // Fork of vapor/mysql-nio 1.9.1 pinned to an exact revision, adding
        // CLIENT_MULTI_RESULTS + multi-result-set draining so a `CALL` to a
        // procedure that returns a SELECT works (upstream fails it with
        // ER_SP_BADSELECT). See that commit's message for the full rationale;
        // revisit if the change lands upstream.
        .package(
            url: "https://github.com/stokay/mysql-nio.git",
            revision: "a637f93245d7b01cb9f2ca86024b9b7d2a3a137a"
        )
    ],
    targets: [
        .executableTarget(
            name: "MySQLMacClient",
            dependencies: [
                .product(name: "MySQLNIO", package: "mysql-nio")
            ],
            resources: [
                .copy("Resources"),
                // `.process`, not `.copy` — a copied .xcstrings would ship as
                // raw JSON and localize nothing; processing runs it through
                // the String Catalog compiler. It also has to live *outside*
                // the `Resources/` folder above, since that whole directory
                // is copied verbatim.
                .process("Localizable.xcstrings")
            ]
        ),
        .testTarget(
            name: "MySQLMacClientTests",
            dependencies: ["MySQLMacClient"]
        )
    ]
)
