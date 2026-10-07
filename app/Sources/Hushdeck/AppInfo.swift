import Foundation

/// Values shown in About. They come from Info.plist, which scripts/build-app.sh writes.
enum AppInfo {
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
    }

    static var copyright: String? {
        Bundle.main.object(forInfoDictionaryKey: "NSHumanReadableCopyright") as? String
    }

    /// Set at build time (`HUSHDECK_REPOSITORY_URL`, filled in automatically on CI).
    /// Links that depend on it are hidden when it's missing.
    static var repositoryURL: URL? {
        guard let string = Bundle.main.object(forInfoDictionaryKey: "HushdeckRepositoryURL") as? String,
              !string.isEmpty else { return nil }
        return URL(string: string)
    }

    static var issuesURL: URL? { repositoryURL?.appendingPathComponent("issues") }

    static let headsetControlURL = URL(string: "https://github.com/Sapd/HeadsetControl")!
    static let gplURL = URL(string: "https://www.gnu.org/licenses/gpl-3.0.html")!
    static let hidapiURL = URL(string: "https://github.com/libusb/hidapi")!

    /// Licence texts copied into Contents/Resources next to the bundled CLI.
    static var headsetControlLicense: URL? {
        Bundle.main.url(forResource: "headsetcontrol-LICENSE", withExtension: "txt")
    }

    static var hidapiLicense: URL? {
        Bundle.main.url(forResource: "hidapi-LICENSE", withExtension: "txt")
    }
}
