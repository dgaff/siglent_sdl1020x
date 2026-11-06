// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LoadLab",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "SCPIKit", targets: ["SCPIKit"]),
        .library(name: "SDLKit", targets: ["SDLKit"]),
        .library(name: "SDLSimulator", targets: ["SDLSimulator"]),
        .executable(name: "sdlctl", targets: ["sdlctl"]),
        .executable(name: "LoadLab", targets: ["LoadLab"]),
    ],
    targets: [
        // Transport + discovery. No UI, no device knowledge.
        .target(name: "SCPIKit"),
        // Typed SDL1000X command set on top of SCPIKit.
        .target(name: "SDLKit", dependencies: ["SCPIKit"]),
        // Fake SDL1000X TCP server reproducing the real device's quirks.
        .target(name: "SDLSimulator", dependencies: ["SCPIKit"]),
        // Command-line tool: discovery, raw queries, monitoring, simulator.
        .executableTarget(name: "sdlctl", dependencies: ["SCPIKit", "SDLKit", "SDLSimulator"]),
        // App logic (session, polling, history, discovery model); UI-free and testable.
        .target(name: "LoadLabCore", dependencies: ["SCPIKit", "SDLKit"]),
        // SwiftUI app.
        .executableTarget(name: "LoadLab", dependencies: ["LoadLabCore", "SCPIKit", "SDLKit"]),

        .testTarget(name: "SCPIKitTests", dependencies: ["SCPIKit", "SDLSimulator"]),
        .testTarget(name: "SDLKitTests", dependencies: ["SDLKit", "SCPIKit", "SDLSimulator"]),
        .testTarget(name: "LoadLabCoreTests", dependencies: ["LoadLabCore", "SDLKit", "SCPIKit", "SDLSimulator"]),
        // Live-hardware tests; skipped unless SDL_HW_HOST is set.
        .testTarget(name: "HardwareTests", dependencies: ["SDLKit", "SCPIKit", "LoadLabCore"]),
    ]
)
