// swift-tools-version:5.9
// The same sources as the Flutter build hook (src/: C++ inside, C API),
// wrapped for Swift. Swift only imports the C header.
// Local path dependency only: unsafeFlags keeps the compiler flags identical
// to hook/build.dart, so results match the Dart side bit for bit.
import PackageDescription

let package = Package(
    name: "EchoCore",
    platforms: [.iOS(.v13), .macOS(.v11)],
    products: [
        .library(name: "EchoCore", targets: ["EchoCore"]),
    ],
    targets: [
        .target(
            name: "CEchoCore",
            path: "src",
            publicHeadersPath: ".",
            cSettings: [
                .unsafeFlags(["-O3", "-Wall", "-Wextra", "-Werror", "-ffp-contract=off"]),
            ],
            cxxSettings: [
                .unsafeFlags(["-O3", "-Wall", "-Wextra", "-Werror", "-ffp-contract=off"]),
            ]
        ),
        .target(
            name: "EchoCore",
            dependencies: ["CEchoCore"],
            path: "swift/Sources/EchoCore"
        ),
        .testTarget(
            name: "EchoCoreTests",
            dependencies: ["EchoCore"],
            path: "swift/Tests/EchoCoreTests"
        ),
    ],
    cLanguageStandard: .c11,
    cxxLanguageStandard: .cxx17
)
