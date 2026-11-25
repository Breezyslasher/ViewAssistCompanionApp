// swift-tools-version:5.9
// Platform-independent parts of the iOS app, so `swift test` can run them:
// the Wyoming protocol, the voice pipeline state machine (a port of the
// Android SatelliteAudioPipeline) and microWakeWord feature extraction.
import PackageDescription

let package = Package(
    name: "VACACore",
    platforms: [.iOS(.v15), .macOS(.v13)],
    products: [
        .library(name: "VACACore", targets: ["VACACore"]),
    ],
    targets: [
        // TensorFlow Lite micro frontend (audio -> 40 log-mel features per
        // 10 ms), the same C code as the Android :microfeatures module.
        .target(
            name: "MicroFrontend",
            exclude: [
                // Compiled as 16-bit fixed point via kiss_fft_int16.cc
                "kissfft/kiss_fft.c",
                "kissfft/tools/kiss_fftr.c",
            ],
            cSettings: [
                .headerSearchPath("."),
                .headerSearchPath("kissfft"),
            ],
            cxxSettings: [
                .headerSearchPath("."),
                .headerSearchPath("kissfft"),
            ]
        ),
        .target(name: "VACACore", dependencies: ["MicroFrontend"]),
        .testTarget(name: "VACACoreTests", dependencies: ["VACACore"]),
    ],
    cxxLanguageStandard: .cxx14
)
