// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "QmouseFix",
    platforms: [.macOS(.v15)], // macOS 15+ only — lets us use modern APIs and drop legacy compat
    targets: [
        .executableTarget(
            name: "QmouseFix",
            path: "Sources/QmouseFix",
            swiftSettings: [
                // v1 uses Swift 5 language mode: the CGEventTap C-callback bridging is simpler
                // without Swift 6 strict-concurrency ceremony. Tighten to .v6 once the engine is stable.
                .swiftLanguageMode(.v5)
            ]
        ),
        .testTarget(
            name: "QmouseFixTests",
            dependencies: ["QmouseFix"],
            path: "Tests/QmouseFixTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
