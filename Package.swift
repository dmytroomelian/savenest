// swift-tools-version: 5.9
import PackageDescription
import Foundation

// Public builds remain independent of separately licensed Pro source.
var packageDependencies: [Package.Dependency] = [.package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0")]
var appDependencies: [Target.Dependency] = ["SaveNestCore", .product(name: "Sparkle", package: "Sparkle")]
if let path = ProcessInfo.processInfo.environment["SAVENEST_PRO_CAPTURE_PACKAGE"], !path.isEmpty {
    packageDependencies.append(.package(name: "SaveNestProCapture", path: path))
    appDependencies.append(.product(name: "SaveNestProCapture", package: "SaveNestProCapture"))
}

let package = Package(
    name: "SaveNest",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "SaveNest", targets: ["SaveNest"])],
    dependencies: packageDependencies,
    targets: [
        .target(name: "SaveNestCore"),
        .executableTarget(name: "SaveNest", dependencies: appDependencies,
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]),
        .executableTarget(name: "SaveNestChecks", dependencies: ["SaveNestCore"], path: "Tests/SaveNestCoreTests")
    ]
)
