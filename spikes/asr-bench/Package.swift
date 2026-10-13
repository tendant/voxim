// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "asr-bench",
    platforms: [.macOS(.v26)],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.7.0"),
    ],
    targets: [
        .executableTarget(
            name: "zh-bench",
            dependencies: [.product(name: "FluidAudio", package: "FluidAudio")],
            swiftSettings: [
                .swiftLanguageMode(.v5),
                .defaultIsolation(MainActor.self),
                .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
                .enableUpcomingFeature("InferIsolatedConformances"),
                .enableUpcomingFeature("MemberImportVisibility"),
            ]
        ),
        .executableTarget(
            name: "asr-bench",
            dependencies: [.product(name: "FluidAudio", package: "FluidAudio")],
            // Mirror the app target so the shared voxim sources compile identically.
            swiftSettings: [
                .swiftLanguageMode(.v5),
                .defaultIsolation(MainActor.self),
                .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
                .enableUpcomingFeature("InferIsolatedConformances"),
                .enableUpcomingFeature("MemberImportVisibility"),
            ]
        ),
    ]
)
