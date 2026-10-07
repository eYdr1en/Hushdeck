import HeadsetControlKit
import SwiftUI

struct DeviceHeader: View {
    @Environment(AppModel.self) private var model
    let device: DeviceInfo

    /// Vendor, product and USB ID, shown when hovering the name.
    private var details: String {
        [device.vendor, device.product, device.deviceID?.filterArgument]
            .compactMap { $0?.isEmpty == false ? $0 : nil }
            .joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "headset")
                .font(.system(size: 17, weight: .regular))
                .foregroundStyle(device.connection.isReachable ? .primary : .tertiary)
                .frame(width: 34, height: 34)
                .background(.quaternary.opacity(0.7), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                if model.devices.count > 1 {
                    Menu {
                        ForEach(model.devices) { candidate in
                            Button(candidate.name) { model.selectDevice(candidate.id) }
                        }
                    } label: {
                        Text(device.name).font(.headline)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                } else {
                    Text(device.name)
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(Text(verbatim: details))
                }
                BatteryLine(device: device)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 10)
    }
}

private struct BatteryLine: View {
    let device: DeviceInfo

    var body: some View {
        HStack(spacing: 5) {
            switch device.connection {
            case .offline(let reason):
                Text("Off or out of range")
                    .foregroundStyle(.secondary)
                    .help(reason.map { Text(verbatim: $0) } ?? Text("The receiver is connected but the headset isn’t responding"))
            case .unknown:
                Text("Connected").foregroundStyle(.secondary)
            case .connected(let charging):
                if let battery = device.battery, let level = battery.percent {
                    Image(systemName: Self.symbol(level: level, charging: charging))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(level <= 15 && !charging ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                    Text(percentString(level))
                        .monospacedDigit()
                    if let detail = Self.detail(battery) {
                        Text(detail).foregroundStyle(.secondary)
                    }
                } else {
                    Group {
                        if charging { Text("Charging") } else { Text("Connected") }
                    }
                    .foregroundStyle(.secondary)
                }
            }
        }
        .font(.subheadline)
        .accessibilityElement(children: .combine)
    }

    static func symbol(level: Int, charging: Bool) -> String {
        if charging { return "battery.100percent.bolt" }
        switch level {
        case ..<13: return "battery.0percent"
        case ..<38: return "battery.25percent"
        case ..<63: return "battery.50percent"
        case ..<88: return "battery.75percent"
        default: return "battery.100percent"
        }
    }

    static func detail(_ battery: BatteryInfo) -> String? {
        if battery.isCharging {
            if let minutes = battery.minutesToFull, minutes > 0 { return String(localized: "Charging, full in \(duration(minutes))") }
            return String(localized: "Charging")
        }
        if let minutes = battery.minutesToEmpty, minutes > 0 { return String(localized: "About \(duration(minutes)) left") }
        return nil
    }

    static func duration(_ minutes: Int) -> String {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.allowedUnits = minutes >= 60 ? [.hour] : [.minute]
        formatter.maximumUnitCount = 1
        let rounded = minutes >= 60 ? (Double(minutes) / 60).rounded() * 3600 : Double(minutes) * 60
        return formatter.string(from: rounded) ?? Duration.seconds(rounded).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))
    }
}
