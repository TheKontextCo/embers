// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "embers",
    defaultLocalization: "en",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "EmbersCore", targets: ["EmbersCore"]),
        .library(name: "EmbersPluginKit", targets: ["EmbersPluginKit"]),
        .library(name: "EmbersPluginHost", targets: ["EmbersPluginHost"]),
        .library(name: "EmbersLocal", targets: ["EmbersLocal"]),
        .library(name: "FolderPlugin", targets: ["FolderPlugin"]),
        .library(name: "KontextPlugin", targets: ["KontextPlugin"]),
    ],
    targets: [
        .target(
            name: "EmbersCore",
            path: "Sources/EmbersCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .target(
            name: "EmbersPluginKit",
            dependencies: ["EmbersCore"],
            path: "Sources/EmbersPluginKit",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .target(
            name: "EmbersPluginHost",
            dependencies: ["EmbersCore", "EmbersPluginKit"],
            path: "Sources/EmbersPluginHost",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .target(
            name: "EmbersLocal",
            dependencies: ["EmbersCore", "EmbersPluginKit"],
            path: "Sources/EmbersLocal",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .target(
            name: "FolderPlugin",
            dependencies: ["EmbersCore", "EmbersPluginKit", "EmbersLocal"],
            path: "Sources/FolderPlugin",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .target(
            name: "KontextPlugin",
            dependencies: ["EmbersCore", "EmbersPluginKit", "EmbersLocal"],
            path: "Sources/KontextPlugin",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "embers",
            dependencies: ["EmbersCore", "EmbersLocal", "EmbersPluginHost", "FolderPlugin", "KontextPlugin"],
            path: "Sources/embers",
            resources: [
                .copy("Resources/SampleVault"),
                .process("Resources/en.lproj"),
            ],
            swiftSettings: [
                // Pragmatic for the first vertical slice; tighten to Swift 6 mode later.
                .swiftLanguageMode(.v5)
            ],
            // Embed Info.plist into the binary's __TEXT,__info_plist section so the bare
            // executable (what `swift run` / Xcode Cmd+R launches) still has a bundle
            // identifier + LSUIElement — without it, the app has no identity, can't become
            // key, and dropdowns/hover die. The .app bundle's own Info.plist still wins when
            // launched via `open`.
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Resources/Info.plist",
                ])
            ]
        ),
        .testTarget(
            name: "embersTests",
            dependencies: ["embers", "EmbersCore", "EmbersLocal", "EmbersPluginHost", "EmbersPluginKit", "FolderPlugin", "KontextPlugin"],
            path: "Tests/embersTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "EmbersCoreTests",
            dependencies: ["EmbersCore"],
            path: "Tests/EmbersCoreTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "EmbersLocalTests",
            dependencies: ["EmbersCore", "EmbersLocal"],
            path: "Tests/EmbersLocalTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "EmbersPluginKitTests",
            dependencies: ["EmbersCore", "EmbersPluginKit"],
            path: "Tests/EmbersPluginKitTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "EmbersPluginHostTests",
            dependencies: ["EmbersCore", "EmbersPluginKit", "EmbersPluginHost", "FolderPlugin", "EmbersLocal"],
            path: "Tests/EmbersPluginHostTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "KontextPluginTests",
            dependencies: ["EmbersCore", "EmbersLocal", "EmbersPluginKit", "KontextPlugin"],
            path: "Tests/KontextPluginTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
