// swift-tools-version: 6.0
import Foundation
import PackageDescription

let nativeCorePath = ".build/pks-native/PKSCore.xcframework"
let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let nativeCoreURL = packageRoot.appendingPathComponent(nativeCorePath)
let hasNativeCore = FileManager.default.fileExists(atPath: nativeCoreURL.path)

var appDependencies: [Target.Dependency] = [
    .product(name: "MarkdownUI", package: "swift-markdown-ui")
]
if hasNativeCore {
    appDependencies.append(.target(name: "PKSCore"))
}

var targets: [Target] = [
    .executableTarget(
        name: "PKSNotes",
        dependencies: appDependencies,
        swiftSettings: [.swiftLanguageMode(.v5)],
        linkerSettings: [.linkedLibrary("z")]
    ),
    .testTarget(
        name: "PKSNotesTests",
        dependencies: ["PKSNotes"],
        resources: [.process("Resources")]
    )
]
if hasNativeCore {
    targets.append(.binaryTarget(name: "PKSCore", path: nativeCorePath))
}

let package = Package(
    name: "Leafspan",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "PKSNotes", targets: ["PKSNotes"])],
    dependencies: [
        .package(url: "https://github.com/gonzalezreal/swift-markdown-ui.git", exact: "2.4.1")
    ],
    targets: targets
)
