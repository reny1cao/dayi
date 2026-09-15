import Foundation
import Testing
@testable import TextPolishApp

@MainActor
struct ChromiumHostTests {
    private func bundle(framework: String?, files: [String]) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "ChromiumHostTests-\(UUID().uuidString)/Host.app")
        var directory = root.appending(path: "Contents/Frameworks")
        if let framework {
            directory = directory.appending(path: "\(framework)/Versions/A/Resources")
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let framework {
            // Real frameworks reach Resources through a symlink; detection must follow it.
            try FileManager.default.createSymbolicLink(
                atPath: root.appending(path: "Contents/Frameworks/\(framework)/Resources").path,
                withDestinationPath: "Versions/A/Resources")
        }
        for file in files { try Data().write(to: directory.appending(path: file)) }
        return root
    }

    @Test func recognisesAnyFrameworkCarryingChromiumResources() throws {
        for framework in ["Electron Framework.framework", "Codex Framework.framework", "Google Chrome Framework.framework"] {
            let url = try bundle(framework: framework, files: ["icudtl.dat", "resources.pak"])
            #expect(AXTextTarget.isChromiumBundle(url), "\(framework)")
        }
    }

    @Test func requiresBothMarkers() throws {
        #expect(!AXTextTarget.isChromiumBundle(try bundle(framework: "FlutterMacOS.framework", files: ["icudtl.dat"])))
        #expect(!AXTextTarget.isChromiumBundle(try bundle(framework: "Sparkle.framework", files: ["resources.pak"])))
        #expect(!AXTextTarget.isChromiumBundle(try bundle(framework: "Sparkle.framework", files: [])))
    }

    @Test func rejectsBundlesWithoutFrameworks() throws {
        #expect(!AXTextTarget.isChromiumBundle(try bundle(framework: nil, files: [])))
        #expect(!AXTextTarget.isChromiumBundle(URL(fileURLWithPath: "/nonexistent/Host.app")))
    }
}
