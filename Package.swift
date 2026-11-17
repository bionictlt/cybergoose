// swift-tools-version: 6.0
import PackageDescription
import Foundation

let sshPrefix = ProcessInfo.processInfo.environment["CYBERGOOSE_SSH2_PREFIX"] ?? (FileManager.default.fileExists(atPath: "/opt/homebrew/opt/libssh2") ? "/opt/homebrew/opt/libssh2" : "/usr/local/opt/libssh2")

let package = Package(
    name: "Cybergoose",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Cybergoose", targets: ["Cybergoose"])],
    targets: [
        .target(name: "CSSHBridge", cSettings: [.unsafeFlags(["-I" + sshPrefix + "/include"])], linkerSettings: [.unsafeFlags(["-L" + sshPrefix + "/lib"]), .linkedLibrary("ssh2")]),
        .target(name: "CCurlBridge", linkerSettings: [.linkedLibrary("curl")]),
        .executableTarget(name: "Cybergoose", dependencies: ["CSSHBridge", "CCurlBridge"])
    ]
)
