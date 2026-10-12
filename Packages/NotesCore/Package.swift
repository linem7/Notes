// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "NotesCore",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "NotesCore", targets: ["NotesCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.11.0"),
    ],
    targets: [
        .target(
            name: "NotesCore",
            dependencies: [.product(name: "GRDB", package: "GRDB.swift")]
        ),
        // 调试用的命令行：用真实 key 跑一次 Organize，不进 app
        .executableTarget(
            name: "notes-debug",
            dependencies: ["NotesCore"]
        ),
        .testTarget(
            name: "NotesCoreTests",
            dependencies: ["NotesCore", .product(name: "GRDB", package: "GRDB.swift")],
            resources: [.copy("Fixtures")]
        ),
    ]
)
