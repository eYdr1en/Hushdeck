import Foundation
import Testing
@testable import Hushdeck

@Suite("Launch at login")
struct LaunchAtLoginTests {
    let home = URL(fileURLWithPath: "/Users/tester")

    @Test func installedLocations() {
        #expect(LaunchAtLogin.isInstalled(URL(fileURLWithPath: "/Applications/Hushdeck.app"), home: home))
        #expect(LaunchAtLogin.isInstalled(URL(fileURLWithPath: "/Users/tester/Applications/Hushdeck.app"), home: home))
    }

    @Test func devBuildsAreNotInstalled() {
        #expect(!LaunchAtLogin.isInstalled(URL(fileURLWithPath: "/Users/tester/coding/Hushdeck/app/dist/Hushdeck.app"), home: home))
        #expect(!LaunchAtLogin.isInstalled(URL(fileURLWithPath: "/Applications/Utilities/Hushdeck.app"), home: home))
        #expect(!LaunchAtLogin.isInstalled(URL(fileURLWithPath: "/Users/tester/coding/Hushdeck/app/.build/debug"), home: home))
    }
}
