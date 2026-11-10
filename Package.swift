// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MessageSearch",
    platforms: [.macOS(.v14)],
    targets: [
        // C header for the Rust core in ./core (built by build.sh before this).
        .target(
            name: "CMsgCore",
            path: "Sources/CMsgCore",
            linkerSettings: [
                .unsafeFlags(["-Lcore/target/release"]),
                .linkedLibrary("msgcore"),
            ]
        ),
        .executableTarget(
            name: "MessageSearch",
            dependencies: ["CMsgCore"],
            path: "Sources/MessageSearch",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
    ]
)
