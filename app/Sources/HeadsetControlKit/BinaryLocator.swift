import Foundation

/// Where the `headsetcontrol` executable was found.
public struct BinaryLocation: Sendable, Equatable {
    public enum Source: String, Sendable, Equatable {
        case userOverride = "Custom path"
        case bundled = "Bundled with Hushdeck"
        case homebrew = "Homebrew"
        case usrLocal = "/usr/local"
        case developmentBuild = "Development build"
    }

    public var url: URL
    public var source: Source

    public init(url: URL, source: Source) {
        self.url = url
        self.source = source
    }
}

/// Resolves the CLI in the order: user override, app bundle Resources,
/// /opt/homebrew/bin, /usr/local/bin, ~/coding/HeadsetControl/build.
public struct BinaryLocator: Sendable {
    public var overridePath: String?
    public var bundleResourcesURL: URL?
    public var homeDirectory: URL
    public var isExecutable: @Sendable (String) -> Bool

    public static let binaryName = "headsetcontrol"

    public init(
        overridePath: String?,
        bundleResourcesURL: URL? = Bundle.main.resourceURL,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        isExecutable: @escaping @Sendable (String) -> Bool = { path in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
                && !isDirectory.boolValue
                && FileManager.default.isExecutableFile(atPath: path)
        }
    ) {
        self.overridePath = overridePath
        self.bundleResourcesURL = bundleResourcesURL
        self.homeDirectory = homeDirectory
        self.isExecutable = isExecutable
    }

    public var candidates: [BinaryLocation] {
        var result: [BinaryLocation] = []
        if let path = trimmedOverride {
            result.append(.init(url: URL(fileURLWithPath: (path as NSString).expandingTildeInPath), source: .userOverride))
        }
        if let resources = bundleResourcesURL {
            result.append(.init(url: resources.appendingPathComponent(Self.binaryName), source: .bundled))
        }
        result.append(.init(url: URL(fileURLWithPath: "/opt/homebrew/bin/headsetcontrol"), source: .homebrew))
        result.append(.init(url: URL(fileURLWithPath: "/usr/local/bin/headsetcontrol"), source: .usrLocal))
        result.append(.init(
            url: homeDirectory.appendingPathComponent("coding/HeadsetControl/build/headsetcontrol"),
            source: .developmentBuild
        ))
        return result
    }

    public func locate() -> BinaryLocation? {
        candidates.first { isExecutable($0.url.path) }
    }

    /// True when the user set an override that doesn't point at an executable.
    public var overrideIsInvalid: Bool {
        guard let path = trimmedOverride else { return false }
        return !isExecutable((path as NSString).expandingTildeInPath)
    }

    private var trimmedOverride: String? {
        guard let path = overridePath?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty else { return nil }
        return path
    }
}
