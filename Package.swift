// swift-tools-version:5.9
import PackageDescription

// Each Clean-Architecture layer is its own module, so the compiler — not code review —
// enforces the dependency rule (inner layers cannot import outer ones):
//
//   Domain  ◄── DataKit ◄── App (composition root, Firebase, SwiftData, OS integrations)
//   Domain  ◄── PresentationKit ◄── App
//   SyncKit, SecurityKit: leaf modules with no knowledge of the domain
//
// Firebase and SwiftData adapters live in `App/` (see README) because they need Xcode's
// iOS SDK / macro plugins; everything below is plain SwiftPM and runs with `swift test`.

let strictConcurrency: [SwiftSetting] = [.enableExperimentalFeature("StrictConcurrency")]

let package = Package(
    name: "FitCoachKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "Domain", targets: ["Domain"]),
        .library(name: "SyncKit", targets: ["SyncKit"]),
        .library(name: "SecurityKit", targets: ["SecurityKit"]),
        .library(name: "DataKit", targets: ["DataKit"]),
        .library(name: "PresentationKit", targets: ["PresentationKit"]),
    ],
    targets: [
        // Pure Swift: entities, engines, use cases, repository *protocols*. Foundation only.
        .target(name: "Domain", swiftSettings: strictConcurrency),
        // Offline mutation queue, sync dispatcher, conflict resolution. Foundation + Network only.
        .target(name: "SyncKit", swiftSettings: strictConcurrency),
        // Keychain, AES-GCM field encryption, SPKI certificate pinning.
        .target(name: "SecurityKit", swiftSettings: strictConcurrency),
        // Offline-first repositories: local store + mutation queue. Implements Domain protocols.
        .target(name: "DataKit", dependencies: ["Domain", "SyncKit", "SecurityKit"], swiftSettings: strictConcurrency),
        // SwiftUI view models, component factory, views.
        .target(name: "PresentationKit", dependencies: ["Domain"], swiftSettings: strictConcurrency),

        .testTarget(name: "DomainTests", dependencies: ["Domain"]),
        .testTarget(name: "SyncKitTests", dependencies: ["SyncKit"]),
        .testTarget(name: "SecurityKitTests", dependencies: ["SecurityKit"]),
        .testTarget(name: "DataKitTests", dependencies: ["DataKit", "Domain", "SyncKit", "SecurityKit"]),
        .testTarget(name: "PresentationKitTests", dependencies: ["PresentationKit", "Domain"]),
    ]
)
