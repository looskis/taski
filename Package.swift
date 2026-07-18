// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Taski",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "TaskiCore", targets: ["TaskiCore"]),
        .executable(name: "taski", targets: ["Taski"]),
        .executable(name: "taski-tests", targets: ["TaskiCoreTests"]),
    ],
    targets: [
        .target(name: "TaskiCore", linkerSettings: [.linkedLibrary("sqlite3")]),
        .executableTarget(name: "Taski", dependencies: ["TaskiCore"]),
        .executableTarget(name: "TaskiCoreTests", dependencies: ["TaskiCore"], path: "Tests/TaskiCoreTests"),
    ]
)
