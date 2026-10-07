import AppKit
import Foundation
import OmniKit
import UniformTypeIdentifiers

extension OmniController {
    var activeProfile: OmniProfile? {
        profiles.first { $0.id == activeProfileID }
    }

    /// Snapshots the device's current settings and EQs under `name`.
    @discardableResult
    func saveProfile(named name: String) -> OmniProfile? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var snapshot = state
        snapshot.settings = settings
        snapshot.equalizers.wireless = wirelessEQ
        snapshot.equalizers.bluetooth = bluetoothEQ
        snapshot.equalizers.mic = micEQ
        let profile = OmniProfile(name: uniqueName(trimmed), snapshotOf: snapshot)
        profiles.append(profile)
        persistProfiles()
        setActiveProfile(profile.id)
        return profile
    }

    /// Overwrites `profile` with what the device reports now.
    func updateProfile(_ profile: OmniProfile) {
        guard let index = profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        var updated = OmniProfile(name: profile.name, snapshotOf: state)
        updated.id = profile.id
        updated.created = profile.created
        updated.settings = settings
        updated.wirelessEQ = wirelessEQ
        updated.bluetoothEQ = bluetoothEQ
        updated.micEQ = micEQ
        profiles[index] = updated
        persistProfiles()
        setActiveProfile(profile.id)
    }

    func rename(_ profile: OmniProfile, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        profiles[index].name = trimmed
        profiles[index].modified = Date()
        persistProfiles()
    }

    @discardableResult
    func duplicate(_ profile: OmniProfile) -> OmniProfile {
        let copy = profile.duplicated(name: uniqueName(String(localized: "\(profile.name) copy", comment: "Name of a duplicated profile")))
        if let index = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles.insert(copy, at: index + 1)
        } else {
            profiles.append(copy)
        }
        persistProfiles()
        return copy
    }

    func delete(_ profile: OmniProfile) {
        profiles.removeAll { $0.id == profile.id }
        if activeProfileID == profile.id { setActiveProfile(nil) }
        persistProfiles()
    }

    func deleteAllProfiles() {
        profiles = []
        setActiveProfile(nil)
        profileStore.removeAll()
    }

    /// Deploys a profile the way GG does: every setting, then save-to-flash. EQs go along
    /// only when experimental EQ writes are on.
    func apply(_ profile: OmniProfile) {
        guard isReady else {
            onMessage?(OmniErrorText.message(for: OmniError.notConnected), true)
            return
        }
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.device.apply(profile.settingsToApply, saveToDevice: true)
                for setting in profile.settingsToApply { self.remember(setting) }
                if self.experimentalEQWrites {
                    if let eq = profile.wirelessEQ { try await self.device.setWirelessEQ(eq); self.wirelessDraft = nil }
                    if let eq = profile.bluetoothEQ { try await self.device.setBluetoothEQ(eq); self.bluetoothDraft = nil }
                    if let eq = profile.micEQ { try await self.device.setMicEQ(eq); self.micDraft = nil }
                }
                self.setActiveProfile(profile.id)
                if profile.includesEqualizers && !self.experimentalEQWrites {
                    self.notify(String(localized: "Applied “\(profile.name)”. Its equalizers were skipped because EQ writes are off."))
                } else {
                    self.notify(String(localized: "Applied “\(profile.name)”"))
                }
            } catch {
                self.report(error)
            }
        }
    }

    // MARK: Import / export

    func importProfile(from data: Data) throws -> OmniProfile {
        var profile = try OmniProfile.imported(from: data)
        profile.name = uniqueName(profile.name)
        profiles.append(profile)
        persistProfiles()
        return profile
    }

    func importProfile(from url: URL) {
        do {
            let profile = try importProfile(from: Data(contentsOf: url))
            notify(String(localized: "Imported “\(profile.name)”"))
        } catch {
            onMessage?(String(localized: "Couldn’t import that profile: \(error.localizedDescription)"), true)
        }
    }

    func export(_ profile: OmniProfile, to url: URL) {
        do {
            try profile.exported().write(to: url, options: .atomic)
            notify(String(localized: "Exported “\(profile.name)”"))
        } catch {
            onMessage?(String(localized: "Couldn’t export the profile: \(error.localizedDescription)"), true)
        }
    }

    /// Shows a save panel and exports.
    func exportWithPanel(_ profile: OmniProfile) {
        let panel = NSSavePanel()
        panel.title = String(localized: "Export Profile")
        panel.nameFieldStringValue = "\(profile.name).\(OmniProfile.fileExtension)"
        panel.allowedContentTypes = [Self.profileContentType]
        panel.canCreateDirectories = true
        NSApp.activate()
        if panel.runModal() == .OK, let url = panel.url { export(profile, to: url) }
    }

    /// Shows an open panel and imports.
    func importWithPanel() {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Import Profile")
        panel.allowedContentTypes = [Self.profileContentType, .json]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        NSApp.activate()
        if panel.runModal() == .OK {
            for url in panel.urls { importProfile(from: url) }
        }
    }

    static let profileContentType: UTType = UTType(exportedAs: "com.adrianhorvath.hushdeck.profile", conformingTo: .json)

    // MARK: Helpers

    private func persistProfiles() {
        profileStore.save(profiles)
    }

    /// "Name", "Name 2", "Name 3"… so two profiles never share a name.
    private func uniqueName(_ base: String) -> String {
        let taken = Set(profiles.map { $0.name.lowercased() })
        guard taken.contains(base.lowercased()) else { return base }
        var n = 2
        while taken.contains("\(base) \(n)".lowercased()) { n += 1 }
        return "\(base) \(n)"
    }
}
