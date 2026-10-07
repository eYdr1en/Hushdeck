import Foundation

/// Which EQ the hub says changed (events 0x1B / 0x1D / 0x1F).
public enum OmniEqualizerKind: String, Codable, Sendable, CaseIterable {
    case wireless
    case mic
    case bluetooth
}

/// Unsolicited hub events (protocol-notes §3.2), decoded. Byte 1 is the opcode; byte 0 (the
/// report ID on the 0xFF00 collection) is not interpreted because its value is unconfirmed.
public enum OmniEvent: Sendable, Hashable {
    /// 0xB5: Bluetooth mode/link and the 2.4 GHz headset link.
    case connection(bluetoothMode: BluetoothMode?, bluetoothLink: BluetoothLinkStatus?, headsetLink: HeadsetLinkState?)
    /// 0xB7: headset %, spare (charger) %, charging state.
    case battery(headset: Int, spare: Int, charging: ChargingState?)
    /// 0xBB.
    case micMute(Bool)
    /// 0x45: hardware ChatMix dial.
    case chatMix(ChatMix)
    /// 0x23: active audio input (0–3; 3 = USB 1 and Xbox both connected).
    case audioInput(Int)
    /// 0x25: the hub's volume knob moved (b2 = new hub volume; seen 6–18 on hardware). While
    /// ChatMix isn't enabled (`01 49`), the dial is a volume knob and sends this, not 0x45.
    case hubVolume(Int)
    /// Echo of a setting changed on the hub (knob / OLED menu), same layout as the write.
    case settingChanged(OmniSetting)
    /// 0x1B / 0x1D / 0x1F: an EQ preset changed on the hub; OmniDevice re-reads that EQ.
    case equalizerChanged(OmniEqualizerKind)

    /// Opcodes that are events. None overlap the query-reply opcodes (B0, 10, 12, 80).
    public static let opcodes: Set<UInt8> = OmniSafety.settingOpcodes.union([0xB5, 0xB7, 0xBB, 0x45, 0x23, 0x25, 0x1B, 0x1D, 0x1F])

    /// Decodes an input report, or returns `nil` if it isn't an event OmniKit knows.
    public init?(report r: [UInt8]) {
        guard r.count >= 2 else { return nil }
        func b(_ i: Int) -> UInt8 { i < r.count ? r[i] : 0 }
        switch r[1] {
        case 0xB5:
            self = .connection(bluetoothMode: BluetoothMode(rawValue: b(2)), bluetoothLink: BluetoothLinkStatus(rawValue: b(3)),
                               headsetLink: HeadsetLinkState(rawValue: b(4)))
        case 0xB7:
            self = .battery(headset: Int(b(2)), spare: Int(b(3)), charging: ChargingState(rawValue: b(4)))
        case 0xBB:
            self = .micMute(b(2) != 0)
        case 0x45:
            self = .chatMix(ChatMix(game: Int(b(2)), chat: Int(b(3))))
        case 0x23:
            self = .audioInput(Int(b(2)))
        case 0x25:
            self = .hubVolume(Int(b(2)))
        case 0x1B:
            self = .equalizerChanged(.wireless)
        case 0x1D:
            self = .equalizerChanged(.mic)
        case 0x1F:
            self = .equalizerChanged(.bluetooth)
        default:
            guard let setting = OmniSetting(echo: r) else { return nil }
            self = .settingChanged(setting)
        }
    }
}

extension OmniSetting {
    /// Decodes a setting echo (or a host write; same layout). Values are not range-checked
    /// here: the hub is the source of truth for what it reports.
    public init?(echo r: [UInt8]) {
        guard r.count >= 2 else { return nil }
        func b(_ i: Int) -> UInt8 { i < r.count ? r[i] : 0 }
        func i(_ index: Int) -> Int { Int(b(index)) }
        switch r[1] {
        case 0x38: self = .sidetone(Sidetone(isEnabled: b(2) != 0, level: i(3)))
        case 0x37: self = .micVolume(i(2))
        case 0x3C:
            guard let nr = MicNoiseReduction(enabled: b(2), level: b(3)) else { return nil }
            self = .micNoiseReduction(nr)
        case 0xBF: self = .mutedMicLEDBrightness(i(2))
        case 0xBD:
            guard let v = ANCMode(rawValue: b(2)) else { return nil }
            self = .ancMode(v)
        case 0xB8:
            guard let v = ANCLevel(rawValue: b(2)) else { return nil }
            self = .ancLevel(v)
        case 0xB9: self = .transparencyLevel(i(2))
        case 0xC1:
            guard let v = OmniTimeout(rawValue: b(2)) else { return nil }
            self = .autoOff(v)
        case 0x27: self = .volumeLimiter(b(2) != 0)
        case 0x43:
            guard let v = OutputMode(rawValue: b(2)) else { return nil }
            self = .outputMode(v)
        // The echo reads main at b2, aux at b4, mic at b5 (b3 repeats main).
        case 0x47: self = .streamMix(StreamMix(main: i(2), aux: i(4), mic: i(5)))
        case 0x85: self = .oledBrightness(i(2))
        case 0x83:
            guard let v = OmniTimeout(rawValue: b(2)) else { return nil }
            self = .screensaverTimeout(v)
        case 0x88:
            guard let v = ScreensaverMode(rawValue: b(2)) else { return nil }
            self = .screensaverMode(v)
        case 0x89:
            guard let v = HomeScreenView(rawValue: b(2)) else { return nil }
            self = .homeScreenView(v)
        case 0x8A:
            guard let v = HomeScreenOption(rawValue: b(2)) else { return nil }
            self = .homeScreenOption(v)
        case 0xB2: self = .bluetoothPowerOnDefault(b(2) != 0)
        case 0xB3:
            guard let v = BluetoothCallBehaviour(rawValue: b(2)) else { return nil }
            self = .bluetoothCallBehaviour(v)
        default: return nil
        }
    }
}
