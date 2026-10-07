import OmniKit
import SwiftUI

/// GG's device card, in full: headset, batteries, firmware, identity and hub state.
struct DeviceInfoTab: View {
    @Environment(OmniController.self) private var omni

    var body: some View {
        let readouts = omni.readouts
        let info = omni.state.info
        Form {
            Section("Headset") {
                ReadoutRow("2.4 GHz link", feature: .headsetLink, value: readouts.headsetLink?.localizedName)
                ReadoutRow("Battery", feature: .headsetBattery, value: readouts.trustedHeadsetBattery.map(percentString))
                ReadoutRow("Charging", feature: .chargingState, value: readouts.charging?.localizedName)
                ReadoutRow("Microphone", feature: .micMute, value: readouts.micMuted.map { $0 ? String(localized: "Muted") : String(localized: "Live", comment: "Microphone is not muted") })
                ReadoutRow("Wireless mode", feature: .wirelessMode, value: readouts.wirelessMode?.localizedName)
            }

            Section {
                ReadoutRow("Spare battery", feature: .spareBattery, value: readouts.spareBattery.map { spare in
                    spare >= 100 ? String(localized: "\(percentString(spare)) · Charged") : String(localized: "\(percentString(spare)) · Charging")
                })
                ReadoutRow("Hub volume", feature: .hubVolume, value: readouts.hubVolume.map { "\($0.formatted()) / 38" })
                ReadoutRow("Audio source", feature: .audioInput, value: readouts.audioInput.map(audioSourceName))
                ReadoutRow("Chat mix", feature: .chatMixDial, value: readouts.chatMix.map {
                    String(localized: "Game \(percentString($0.game)) · Chat \(percentString($0.chat))")
                })
                ReadoutRow("Bluetooth", feature: .bluetoothStatus, value: readouts.bluetoothMode?.localizedName)
            } header: {
                Text("GameHub")
            } footer: {
                Text("Chat mix follows the dial on the hub. On a Mac it is a readout only: SteelSeries Sonar, which mixes game and chat in software, isn’t available for macOS.")
                    .sectionFooterStyle()
            }

            Section {
                OmniIssueRow(issues: omni.issues(in: .firmware))
                ReadoutRow("Transmitter MCU 1", feature: .firmwareVersions, value: info.firmware?.hubMCU1.nonEmpty)
                ReadoutRow("Transmitter MCU 2", feature: .firmwareVersions, value: info.firmware?.hubMCU2.nonEmpty)
                ReadoutRow("DSP", feature: .firmwareVersions, value: info.firmware?.hubDSP.nonEmpty)
                ReadoutRow("Receiver MCU", feature: .firmwareVersions, value: info.firmware?.headsetMCU.nonEmpty)
                ReadoutRow("Bluetooth", feature: .firmwareVersions, value: info.firmware?.headsetBluetooth.nonEmpty)
            } header: {
                Text("Firmware")
            } footer: {
                Text("Firmware updates need SteelSeries GG. Hushdeck never sends update or bootloader commands.")
                    .sectionFooterStyle()
            }

            Section("Identity") {
                OmniIssueRow(issues: omni.issues(in: .serial))
                ReadoutRow("Serial number", feature: .serialNumber, value: info.serialNumber?.nonEmpty)
                ReadoutRow("Colour", feature: .colourVariant, value: info.colour?.localizedName)
                if let hub = omni.state.connection.hub {
                    ReadoutRow("USB product", value: hub.productName)
                    ReadoutRow("USB serial", value: hub.usbSerialNumber)
                    ReadoutRow("USB ID", value: String(format: "%04X:%04X", hub.vendorID, hub.productID))
                    if let release = hub.releaseNumber {
                        ReadoutRow("USB release", value: String(format: "%d.%02X", release >> 8, release & 0xFF))
                    }
                }
            }

            Section("Connection") {
                ReadoutRow("Backend", value: omni.isSimulated ? String(localized: "OmniKit (simulated GameHub)") : String(localized: "OmniKit (USB HID)"))
                ReadoutRow("Last full read", value: omni.state.lastRefresh?.formatted(date: .omitted, time: .standard))
                ReadoutRow("Last hub event", feature: .hubEvents, value: omni.state.lastEvent?.formatted(date: .omitted, time: .standard))
                if !omni.issues.isEmpty {
                    LabeledContent("Read problems") {
                        VStack(alignment: .trailing, spacing: 2) {
                            ForEach(omni.issues) { issue in
                                Text(verbatim: issue.raw)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.trailing)
                            }
                        }
                    }
                }
                OmniVerificationNote()
            }
        }
        .formStyle(.grouped)
    }

    private func audioSourceName(_ input: Int) -> String {
        switch input {
        case 0: String(localized: "USB 1", comment: "Audio source")
        case 1: String(localized: "USB 2", comment: "Audio source")
        case 2: String(localized: "USB 3", comment: "Audio source")
        case 3: String(localized: "USB 1 and Xbox", comment: "Audio source")
        default: input.formatted()
        }
    }
}

extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
