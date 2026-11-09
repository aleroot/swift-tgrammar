// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "swift-tgrammar",
    platforms: [
        .macOS(.v15),
        .iOS(.v18),
        .tvOS(.v18),
        .watchOS(.v11),
        .visionOS(.v2),
    ],
    products: [
        .library(name: "TGrammar", targets: ["TGrammar"]),
    ],
    targets: [
        .target(
            name: "TGrammar",
            swiftSettings: [
                .enableUpcomingFeature("ExistentialAny"),
            ]
        ),
        .testTarget(
            name: "TGrammarTests",
            dependencies: ["TGrammar"],
            resources: [.process("Fixtures")]
        ),
    ],
    swiftLanguageModes: [.v6]
)
