// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MySQLMacClient",
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
                .copy("Resources")
            ]
        ),
        .testTarget(
            name: "MySQLMacClientTests",
            dependencies: ["MySQLMacClient"]
        )
    ]
)
