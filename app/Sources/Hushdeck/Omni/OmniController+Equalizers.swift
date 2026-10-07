import Foundation
import OmniKit

extension OmniController {
    // MARK: Effective EQs (draft over device)

    var wirelessEQ: WirelessEQ {
        wirelessDraft ?? state.equalizers.wireless ?? WirelessEQ(preset: .flat, shortName: "FLAT", name: "Flat", bands: ParametricBand.flat)
    }

    var bluetoothEQ: BluetoothEQ {
        bluetoothDraft ?? state.equalizers.bluetooth ?? BluetoothEQ(preset: .flat, shortName: "FLAT", name: "Flat", gainsTenths: BluetoothEQ.flatGains)
    }

    var micEQ: MicEQ {
        micDraft ?? state.equalizers.mic ?? MicEQ(preset: .flat, shortName: "FLAT", name: "Flat", gainsTenths: MicEQ.flatGains)
    }

    func isDirty(_ kind: EQKind) -> Bool {
        switch kind {
        case .wireless: wirelessDraft != nil && wirelessDraft != state.equalizers.wireless
        case .bluetooth: bluetoothDraft != nil && bluetoothDraft != state.equalizers.bluetooth
        case .mic: micDraft != nil && micDraft != state.equalizers.mic
        }
    }

    /// `true` when the device has reported this EQ at least once.
    func hasDeviceEQ(_ kind: EQKind) -> Bool {
        switch kind {
        case .wireless: state.equalizers.wireless != nil
        case .bluetooth: state.equalizers.bluetooth != nil
        case .mic: state.equalizers.mic != nil
        }
    }

    // MARK: Editing

    func updateWirelessBand(_ index: Int, _ change: (inout ParametricBand) -> Void) {
        var eq = wirelessEQ
        guard eq.bands.indices.contains(index) else { return }
        change(&eq.bands[index])
        eq.bands[index].gainTenths = min(max(eq.bands[index].gainTenths, ParametricBand.gainTenthsRange.lowerBound), ParametricBand.gainTenthsRange.upperBound)
        eq.bands[index].qThousandths = min(max(eq.bands[index].qThousandths, ParametricBand.qThousandthsRange.lowerBound), ParametricBand.qThousandthsRange.upperBound)
        if eq.bands[index].frequency != ParametricBand.disabledFrequency {
            eq.bands[index].frequency = min(max(eq.bands[index].frequency, ParametricBand.frequencyRange.lowerBound), ParametricBand.frequencyRange.upperBound)
        }
        let wasCustom = eq.preset == .custom
        eq.preset = .custom
        eq.shortName = customShortName(for: eq.shortName, wasCustom: wasCustom)
        eq.name = customName(for: eq.name, wasCustom: wasCustom)
        wirelessDraft = eq
    }

    func updateGraphicGain(_ kind: EQKind, band index: Int, gainTenths: Int) {
        let clamped = min(max(gainTenths, BluetoothEQ.uiGainTenthsRange.lowerBound), BluetoothEQ.uiGainTenthsRange.upperBound)
        switch kind {
        case .bluetooth:
            var eq = bluetoothEQ
            guard eq.gainsTenths.indices.contains(index) else { return }
            eq.gainsTenths[index] = clamped
            let wasCustom = eq.preset == .custom
            eq.preset = .custom
            eq.shortName = customShortName(for: eq.shortName, wasCustom: wasCustom)
            eq.name = customName(for: eq.name, wasCustom: wasCustom)
            bluetoothDraft = eq
        case .mic:
            var eq = micEQ
            guard eq.gainsTenths.indices.contains(index) else { return }
            eq.gainsTenths[index] = clamped
            let wasCustom = eq.preset == .custom
            eq.preset = .custom
            eq.shortName = customShortName(for: eq.shortName, wasCustom: wasCustom)
            eq.name = customName(for: eq.name, wasCustom: wasCustom)
            micDraft = eq
        case .wireless:
            break
        }
    }

    /// Editing a factory preset turns it into the Custom slot, named "Custom" like GG does (the
    /// hub only accepts bands on that slot). A custom slot keeps its saved name.
    private func customShortName(for current: String, wasCustom: Bool) -> String {
        guard wasCustom else { return "CUSTOM" }
        return current.isEmpty || current.uppercased() != current ? "CUSTOM" : current
    }

    private func customName(for current: String, wasCustom: Bool) -> String {
        guard wasCustom, !current.isEmpty else { return "Custom" }
        return current
    }

    func flatten(_ kind: EQKind) {
        switch kind {
        case .wireless:
            var eq = wirelessEQ
            eq.bands = ParametricBand.flat
            eq.preset = .custom
            wirelessDraft = eq
        case .bluetooth:
            var eq = bluetoothEQ
            eq.gainsTenths = BluetoothEQ.flatGains
            eq.preset = .custom
            bluetoothDraft = eq
        case .mic:
            var eq = micEQ
            eq.gainsTenths = MicEQ.flatGains
            eq.preset = .custom
            micDraft = eq
        }
    }

    func revert(_ kind: EQKind) {
        switch kind {
        case .wireless: wirelessDraft = nil
        case .bluetooth: bluetoothDraft = nil
        case .mic: micDraft = nil
        }
    }

    // MARK: Presets

    /// Loads a factory preset into the draft (and sends it when EQ writes are on).
    func selectWirelessPreset(_ preset: WirelessEQPreset) {
        var eq = wirelessEQ
        eq.preset = preset
        eq.name = preset.displayName
        eq.shortName = preset.shortName
        if let bands = FactoryEQPresets.wirelessBands(preset) {
            eq.bands = bands
        } else if preset == .custom, let stored = state.equalizers.wirelessCustomBands {
            eq.bands = stored
            eq.name = state.equalizers.presetName(.wirelessCustom)?.name ?? eq.name
            eq.shortName = state.equalizers.presetName(.wirelessCustom)?.shortName ?? eq.shortName
        }
        wirelessDraft = eq
        applyIfWritesAreOn(.wireless)
    }

    func selectBluetoothPreset(_ preset: BluetoothEQPreset) {
        var eq = bluetoothEQ
        eq.preset = preset
        eq.name = preset.displayName
        eq.shortName = preset.shortName
        if let gains = FactoryEQPresets.bluetoothGains(preset) { eq.gainsTenths = gains }
        bluetoothDraft = eq
        applyIfWritesAreOn(.bluetooth)
    }

    func selectMicPreset(_ preset: MicEQPreset) {
        var eq = micEQ
        eq.preset = preset
        eq.name = preset.displayName
        eq.shortName = preset.shortName
        if let gains = FactoryEQPresets.micGains(preset) { eq.gainsTenths = gains }
        micDraft = eq
        applyIfWritesAreOn(.mic)
    }

    func selectCustomPreset(_ preset: CustomEQPreset) {
        switch (preset.kind, preset.curve) {
        case (.wireless, .parametric(let bands)):
            var eq = wirelessEQ
            eq.preset = .custom
            eq.name = preset.name
            eq.shortName = preset.shortName
            eq.bands = bands
            wirelessDraft = eq
        case (.bluetooth, .graphic(let gains)):
            var eq = bluetoothEQ
            eq.preset = .custom
            eq.name = preset.name
            eq.shortName = preset.shortName
            eq.gainsTenths = gains
            bluetoothDraft = eq
        case (.mic, .graphic(let gains)):
            var eq = micEQ
            eq.preset = .custom
            eq.name = preset.name
            eq.shortName = preset.shortName
            eq.gainsTenths = gains
            micDraft = eq
        default:
            return
        }
        applyIfWritesAreOn(preset.kind)
    }

    private func applyIfWritesAreOn(_ kind: EQKind) {
        guard experimentalEQWrites, isReady else { return }
        apply(kind)
    }

    func customPresets(for kind: EQKind) -> [CustomEQPreset] {
        customPresets.filter { $0.kind == kind }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Saves the current curve of `kind` under `name`, replacing a preset of the same name.
    func saveCustomPreset(_ kind: EQKind, name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let curve: EQPresetCurve
        switch kind {
        case .wireless: curve = .parametric(wirelessEQ.bands)
        case .bluetooth: curve = .graphic(gainsTenths: bluetoothEQ.gainsTenths)
        case .mic: curve = .graphic(gainsTenths: micEQ.gainsTenths)
        }
        customPresets.removeAll { $0.kind == kind && $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }
        customPresets.append(CustomEQPreset(kind: kind, name: trimmed, curve: curve))
        presetStore.save(customPresets)
        // Name the draft after the preset so the OLED alias matches.
        switch kind {
        case .wireless:
            var eq = wirelessEQ; eq.name = trimmed; eq.shortName = CustomEQPreset(kind: kind, name: trimmed, curve: curve).shortName; eq.preset = .custom
            wirelessDraft = eq
        case .bluetooth:
            var eq = bluetoothEQ; eq.name = trimmed; eq.shortName = CustomEQPreset(kind: kind, name: trimmed, curve: curve).shortName; eq.preset = .custom
            bluetoothDraft = eq
        case .mic:
            var eq = micEQ; eq.name = trimmed; eq.shortName = CustomEQPreset(kind: kind, name: trimmed, curve: curve).shortName; eq.preset = .custom
            micDraft = eq
        }
    }

    func deleteCustomPreset(_ preset: CustomEQPreset) {
        customPresets.removeAll { $0.id == preset.id }
        presetStore.save(customPresets)
    }

    // MARK: Sending

    /// Uploads the draft of `kind`. Needs `experimentalEQWrites`; otherwise explains why not.
    func apply(_ kind: EQKind) {
        guard experimentalEQWrites else {
            onMessage?(OmniErrorText.message(for: OmniError.experimentalEQWritesDisabled), true)
            return
        }
        Task { [weak self] in
            guard let self else { return }
            do {
                switch kind {
                case .wireless:
                    let eq = self.wirelessEQ
                    try await self.device.setWirelessEQ(eq)
                    self.wirelessDraft = nil
                case .bluetooth:
                    let eq = self.bluetoothEQ
                    try await self.device.setBluetoothEQ(eq)
                    self.bluetoothDraft = nil
                case .mic:
                    let eq = self.micEQ
                    try await self.device.setMicEQ(eq)
                    self.micDraft = nil
                }
                if self.activeProfileID != nil { self.setActiveProfile(nil) }
                // Factory slots keep the hub's own curve (it ignores uploaded bands for them), so
                // show what the hub actually has now.
                try await self.device.refreshEqualizer(kind.omniKind)
            } catch {
                self.report(error)
            }
        }
    }

    /// Re-reads one EQ from the hub, dropping the draft.
    func reload(_ kind: EQKind) {
        revert(kind)
        Task { [weak self] in
            guard let self else { return }
            do { try await self.device.refreshEqualizer(kind.omniKind) } catch { self.report(error) }
        }
    }
}
