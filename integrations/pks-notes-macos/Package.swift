// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Leafspan",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "PKSNotes", targets: ["PKSNotes"])],
    dependencies: [
        .package(url: "https://github.com/gonzalezreal/swift-markdown-ui.git", exact: "2.4.1")
    ],
    targets: [
        .executableTarget(
            name: "PKSNotes",
            dependencies: [.product(name: "MarkdownUI", package: "swift-markdown-ui")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(name: "PKSNotesTests", dependencies: ["PKSNotes"], resources: [.process("Resources")])
    ]
)
