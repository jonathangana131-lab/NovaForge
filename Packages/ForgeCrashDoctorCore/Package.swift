// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "ForgeCrashDoctorCore",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "ForgeCrashDoctorCore", targets: ["ForgeCrashDoctorCore"]),
    ],
    targets: [
        .target(name: "ForgeCrashDoctorCore"),
        .testTarget(name: "ForgeCrashDoctorCoreTests", dependencies: ["ForgeCrashDoctorCore"]),
    ]
)
