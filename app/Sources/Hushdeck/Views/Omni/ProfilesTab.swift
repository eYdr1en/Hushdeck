import OmniKit
import SwiftUI

/// GG's configurations: named snapshots of every setting, applied with a save-to-flash.
struct ProfilesTab: View {
    @Environment(OmniController.self) private var omni
    @State private var isNaming = false
    @State private var newName = ""
    @State private var renaming: OmniProfile?
    @State private var renameText = ""

    var body: some View {
        Form {
            Section {
                HStack(spacing: 10) {
                    Button {
                        newName = suggestedName()
                        isNaming = true
                    } label: {
                        Label("Save Current Settings…", systemImage: "plus")
                    }
                    .disabled(!omni.isReady)
                    .popover(isPresented: $isNaming, arrowEdge: .bottom) {
                        NameSheet(title: "Save the GameHub’s current settings as a profile", name: $newName, action: "Save") {
                            omni.saveProfile(named: newName)
                            isNaming = false
                        }
                    }
                    Button {
                        omni.importWithPanel()
                    } label: {
                        Label("Import…", systemImage: "square.and.arrow.down")
                    }
                    Spacer()
                }
            } footer: {
                Text("A profile stores every setting from the Audio, Microphone and Headset & Hub tabs, plus the three equalizers. Applying one sends the settings and saves them to the GameHub, the way SteelSeries GG deploys a configuration. Equalizers are sent only while EQ writes are on.")
                    .sectionFooterStyle()
            }

            Section("Profiles") {
                if omni.profiles.isEmpty {
                    HStack(spacing: 10) {
                        Image(systemName: "person.crop.rectangle.stack")
                            .font(.title2)
                            .foregroundStyle(.tertiary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("No profiles yet")
                            Text("Save the current settings to create one. Profiles can also be switched from the menu bar.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 6)
                } else {
                    ForEach(omni.profiles) { profile in
                        ProfileRow(profile: profile) {
                            renameText = profile.name
                            renaming = profile
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .sheet(item: $renaming) { profile in
            NameSheet(title: "Rename profile", name: $renameText, action: "Rename") {
                omni.rename(profile, to: renameText)
                renaming = nil
            }
            .frame(width: 320)
        }
    }

    private func suggestedName() -> String {
        let base = String(localized: "Profile", comment: "Default name for a new profile")
        return "\(base) \(omni.profiles.count + 1)"
    }
}

private struct ProfileRow: View {
    @Environment(OmniController.self) private var omni
    let profile: OmniProfile
    let onRename: () -> Void

    private var isActive: Bool { omni.activeProfileID == profile.id }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: isActive ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isActive ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.quaternary))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(verbatim: profile.name)
                        .font(.body.weight(isActive ? .semibold : .regular))
                    if isActive {
                        Text("Active")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(.quaternary, in: Capsule())
                    }
                }
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            Button("Apply") { omni.apply(profile) }
                .disabled(!omni.isReady)
                .help("Send every setting in this profile to the GameHub and save it there")
            Menu {
                Button("Update from Current Settings") { omni.updateProfile(profile) }
                    .disabled(!omni.isReady)
                Button("Rename…", action: onRename)
                Button("Duplicate") { omni.duplicate(profile) }
                Button("Export…") { omni.exportWithPanel(profile) }
                Divider()
                Button("Delete", role: .destructive) { omni.delete(profile) }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(verbatim: profile.name))
    }

    private var summary: String {
        var parts: [String] = []
        if let anc = profile.settings.ancMode {
            parts.append(anc.localizedName)
        }
        if let eq = profile.wirelessEQ {
            parts.append(String(localized: "EQ \(eq.name.isEmpty ? String(localized: "Custom") : eq.name)", comment: "Profile summary: 2.4 GHz EQ preset name"))
        }
        if let sidetone = profile.settings.sidetone {
            parts.append(sidetone.isEnabled ? String(localized: "Sidetone \(sidetone.level)") : String(localized: "Sidetone off"))
        }
        if let autoOff = profile.settings.autoOff {
            parts.append(autoOff == .never ? String(localized: "Never turns off") : String(localized: "Off after \(autoOff.minutes) min"))
        }
        let date = profile.modified.formatted(date: .abbreviated, time: .shortened)
        parts.append(String(localized: "\(profile.settingsToApply.count) settings · \(date)", comment: "Profile summary: count and modification date"))
        return parts.joined(separator: " · ")
    }
}

private struct NameSheet: View {
    let title: LocalizedStringKey
    @Binding var name: String
    let action: LocalizedStringKey
    let onConfirm: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            TextField("Name", text: $name, prompt: Text("Profile name"))
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 240)
                .onSubmit(onConfirm)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(action, action: onConfirm)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(14)
    }
}
