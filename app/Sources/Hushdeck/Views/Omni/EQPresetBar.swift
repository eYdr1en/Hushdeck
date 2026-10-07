import OmniKit
import SwiftUI

/// Which preset the picker shows: an onboard slot or a locally saved curve.
enum EQPresetChoice: Hashable {
    case factory(UInt8)
    case custom(UUID)
}

/// Preset picker, save-as, and the on-hub readout shared by the three EQ editors.
struct EQPresetBar: View {
    @Environment(OmniController.self) private var omni
    let kind: EQKind
    /// Onboard slots in display order: (index, name).
    let factory: [(index: UInt8, name: String)]
    let currentIndex: UInt8
    let currentName: String
    let onSelectFactory: (UInt8) -> Void

    @State private var isSavingPreset = false
    @State private var newPresetName = ""

    private var selection: Binding<EQPresetChoice> {
        Binding(
            get: {
                if let match = omni.customPresets(for: kind).first(where: { $0.name == currentName }) {
                    return .custom(match.id)
                }
                return .factory(currentIndex)
            },
            set: { choice in
                switch choice {
                case .factory(let index): onSelectFactory(index)
                case .custom(let id):
                    if let preset = omni.customPresets.first(where: { $0.id == id }) { omni.selectCustomPreset(preset) }
                }
            }
        )
    }

    var body: some View {
        HStack(spacing: 8) {
            Picker(selection: selection) {
                Section {
                    ForEach(factory, id: \.index) { entry in
                        Text(verbatim: entry.name).tag(EQPresetChoice.factory(entry.index))
                    }
                    if !factory.contains(where: { $0.index == currentIndex }) {
                        Text(verbatim: currentName.isEmpty ? String(localized: "Preset \(Int(currentIndex) + 1)", comment: "Equalizer preset without a name") : currentName)
                            .tag(EQPresetChoice.factory(currentIndex))
                    }
                } header: {
                    Text("On the hub")
                }
                let custom = omni.customPresets(for: kind)
                if !custom.isEmpty {
                    Section("Saved in Hushdeck") {
                        ForEach(custom) { preset in
                            Text(verbatim: preset.name).tag(EQPresetChoice.custom(preset.id))
                        }
                    }
                }
            } label: {
                Text("Preset")
            }
            .fixedSize()

            Menu {
                Button("Save as Preset…") {
                    newPresetName = currentName == "Custom" || currentName.isEmpty ? "" : currentName
                    isSavingPreset = true
                }
                let custom = omni.customPresets(for: kind)
                if !custom.isEmpty {
                    Menu("Delete Saved Preset") {
                        ForEach(custom) { preset in
                            Button(preset.name, role: .destructive) { omni.deleteCustomPreset(preset) }
                        }
                    }
                }
                Divider()
                Button("Reload from Hub") { omni.reload(kind) }
                    .disabled(!omni.isReady)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Save, delete or reload presets")
            .popover(isPresented: $isSavingPreset, arrowEdge: .bottom) {
                SavePresetSheet(name: $newPresetName) {
                    omni.saveCustomPreset(kind, name: newPresetName)
                    isSavingPreset = false
                }
            }

            Spacer()

            if omni.hasDeviceEQ(kind), let deviceName = deviceEQName {
                HStack(spacing: 4) {
                    Image(systemName: "rectangle.on.rectangle.angled")
                        .imageScale(.small)
                    Text("On the hub: \(deviceName)")
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .layoutPriority(-1) // truncate rather than wrap, which stretched the row
                .font(.caption)
                .foregroundStyle(.secondary)
                .help("What the GameHub reports right now. The OLED shows the short name.")
            }
        }
    }

    /// "Flat (FLAT)" as the hub reports it.
    private var deviceEQName: String? {
        let name: String, short: String
        switch kind {
        case .wireless:
            guard let eq = omni.state.equalizers.wireless else { return nil }
            name = eq.name; short = eq.shortName
        case .bluetooth:
            guard let eq = omni.state.equalizers.bluetooth else { return nil }
            name = eq.name; short = eq.shortName
        case .mic:
            guard let eq = omni.state.equalizers.mic else { return nil }
            name = eq.name; short = eq.shortName
        }
        if name.isEmpty && short.isEmpty { return String(localized: "unnamed", comment: "EQ preset without a stored name") }
        if short.isEmpty || short == name.uppercased() { return name }
        return "\(name) (\(short))"
    }
}

private struct SavePresetSheet: View {
    @Binding var name: String
    let onSave: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Save the current curve as a preset")
                .font(.headline)
            TextField("Name", text: $name, prompt: Text("Preset name"))
                .textFieldStyle(.roundedBorder)
                .frame(width: 240)
                .onSubmit(onSave)
            Text("The first six letters appear on the GameHub’s screen.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Save", action: onSave)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(14)
    }
}

/// Flat / Revert / Apply plus the explanation while uploads are off.
struct EQActionBar: View {
    @Environment(OmniController.self) private var omni
    @Environment(WindowNavigator.self) private var navigator
    let kind: EQKind

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button("Flat") { omni.flatten(kind) }
                    .help("Set every band to 0 dB")
                Spacer()
                if omni.isDirty(kind) {
                    Button("Revert") { omni.revert(kind) }
                    Button("Send to Hub") { omni.apply(kind) }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!omni.experimentalEQWrites || !omni.isReady)
                        .help(omni.experimentalEQWrites ? "Upload this equalizer to the GameHub" : "Turn on EQ writes in Settings → Developer first")
                }
            }
            .controlSize(.small)
            if !omni.experimentalEQWrites {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "lock")
                        .foregroundStyle(.secondary)
                    Text("Equalizer uploads are switched off, so edits stay in Hushdeck. Turn them on in Settings → Developer.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Developer Settings") { navigator.tab = .settings }
                        .buttonStyle(.link)
                }
                .font(.caption)
            }
        }
    }
}
