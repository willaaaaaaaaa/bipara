import AppKit
import Darwin
import Foundation

/// Both the mounted DMG and the source build use the same installation transaction.
public enum AppInstaller {
    public static let destination = URL(fileURLWithPath: "/Applications/Bipara.app", isDirectory: true)
    private static let identifier = "dev.bipara.Bipara"

    struct Failure: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    struct Source: Decodable {
        let commits: [String]
        let modified: Bool
    }

    struct Version {
        let numbers: [Int]
        let source: Source?

        init(app: URL) throws {
            let data = try Data(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
            let info = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
            guard info?["CFBundleIdentifier"] as? String == AppInstaller.identifier,
                  let version = info?["CFBundleShortVersionString"] as? String,
                  let build = info?["CFBundleVersion"] as? String else {
                throw Failure("A different application occupies the Bipara path.")
            }
            let fields = version.components(separatedBy: ".") + [build]
            numbers = fields.compactMap(Int.init)
            guard fields.count == 4, numbers.count == 4, numbers.allSatisfy({ $0 >= 0 }) else {
                throw Failure("Bipara has an invalid version number.")
            }
            let stamp = app.appendingPathComponent("Contents/Resources/BuildSource.json")
            source = FileManager.default.fileExists(atPath: stamp.path)
                ? try JSONDecoder().decode(Source.self, from: Data(contentsOf: stamp)) : nil
        }

        func checkUpgrade(from installed: Self, localRebuild: Bool) throws {
            if numbers != installed.numbers {
                guard installed.numbers.lexicographicallyPrecedes(numbers) else {
                    throw Failure("A newer Bipara version is already installed.")
                }
                return
            }
            guard let source, let previous = installed.source, let old = previous.commits.first,
                  source.commits.contains(old) else {
                throw Failure("This build is older, or its source history cannot establish an upgrade.")
            }
            if source.commits.first == old && previous.modified && !(localRebuild && source.modified) {
                throw Failure("The installed build contains local changes at this revision.")
            }
        }
    }

    private static func run(_ executable: String, _ args: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw Failure("\(URL(fileURLWithPath: executable).lastPathComponent) failed.") }
    }

    @MainActor
    public static func install(_ candidate: URL, localRebuild: Bool = false) throws {
        let fm = FileManager.default
        let folder = destination.deletingLastPathComponent()
        let fd = Darwin.open(folder.path, O_RDONLY)
        guard fd >= 0 else { throw POSIXError(.EACCES) }
        defer { Darwin.close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw Failure("Another installation is in progress.") }

        let stage = folder.appendingPathComponent(".bipara-install-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: stage, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: stage) }
        let app = stage.appendingPathComponent("Bipara.app", isDirectory: true)
        try run("/usr/bin/ditto", [candidate.path, app.path])
        try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", "-R", "=identifier \"dev.bipara.Bipara\"", app.path])
        let version = try Version(app: app)
        let bundle = Bundle(url: app)
        if let minimum = bundle?.object(forInfoDictionaryKey: "LSMinimumSystemVersion") as? String {
            let os = ProcessInfo.processInfo.operatingSystemVersion
            let current = "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
            guard current.compare(minimum, options: .numeric) != .orderedAscending else {
                throw Failure("This Bipara requires macOS \(minimum) or later.")
            }
        }
        guard bundle?.executableArchitectures?.contains(NSNumber(value: nativeArchitecture)) == true else {
            throw Failure("Choose the Bipara download for this Mac’s processor.")
        }
        let exists = fm.fileExists(atPath: destination.path)
        if exists {
            guard try destination.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
                throw Failure("The Bipara installation path is a symbolic link.")
            }
            let installed = try Version(app: destination)
            // Identical signed executables seal the same resources, including the source stamp.
            let binary = "Contents/MacOS/Bipara"
            if !fm.contentsEqual(atPath: app.appendingPathComponent(binary).path,
                                 andPath: destination.appendingPathComponent(binary).path) {
                try version.checkUpgrade(from: installed, localRebuild: localRebuild)
            }
        }
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: identifier).contains(where: {
            $0.processIdentifier != getpid() && $0.bundleURL?.standardizedFileURL.path == destination.path && !$0.isTerminated
        }) else { throw Failure("Save your documents and quit the installed Bipara, then retry.") }
        let flags = exists ? RENAME_SWAP : RENAME_EXCL
        guard renamex_np(app.path, destination.path, UInt32(flags)) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }

    private static var nativeArchitecture: Int32 {
        var supported: Int32 = 0
        var size = MemoryLayout.size(ofValue: supported)
        sysctlbyname("hw.optional.arm64", &supported, &size, nil, 0)
        return supported == 1 ? CPU_TYPE_ARM64 : CPU_TYPE_X86_64
    }
}
