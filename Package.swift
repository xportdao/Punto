// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "Punto",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "Punto", targets: ["Punto"])
    ],
    targets: [
        .executableTarget(
            name: "Punto",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("Carbon"),
                .linkedFramework("NaturalLanguage"),
                .linkedFramework("Speech")
            ]
        ),
        .testTarget(name: "PuntoTests", dependencies: ["Punto"])
    ]
)
