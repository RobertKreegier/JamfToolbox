// swift-tools-version: 5.9
import PackageDescription

// Shared by Jamf Toolbox for Mac and Jamf Toolbox for iOS/iPadOS: the Jamf Pro
// and Meraki clients, audits, scope editing and other UI-free code.
let package = Package(
    name: "JamfToolboxCore",
    platforms: [.macOS(.v13), .iOS("18.0")],
    products: [
        .library(name: "JamfToolboxCore", targets: ["JamfToolboxCore"]),
    ],
    targets: [
        .target(
            name: "JamfToolboxCore",
            swiftSettings: [.enableUpcomingFeature("InferSendableFromCaptures")]
        ),
        .testTarget(
            name: "JamfToolboxCoreTests",
            dependencies: ["JamfToolboxCore"],
            resources: [.copy("Golden")]
        ),
    ]
)
