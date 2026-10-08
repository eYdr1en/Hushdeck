import Foundation
import OmniKit
import SwiftUI

extension OmniController {
    /// Sends one setting. Sliders pass a debounce so dragging sends one command after the hand
    /// stops. The value shows immediately through the overlay; the device confirms it on the
    /// next event or poll.
    func set(_ setting: OmniSetting, debounce: Duration? = nil) {
        let key = setting.feature
        overlay[key] = setting
        if activeProfileID != nil { setActiveProfile(nil) }
        pendingWrites[key]?.cancel()
        let generation = (writeGeneration[key] ?? 0) + 1
        writeGeneration[key] = generation
        pendingWrites[key] = Task { [weak self] in
            if let debounce {
                try? await Task.sleep(for: debounce)
                if Task.isCancelled { return }
            }
            guard let self else { return }
            defer {
                if self.writeGeneration[key] == generation {
                    self.pendingWrites[key] = nil
                    self.overlay[key] = nil
                }
            }
            do {
                try await self.device.apply(setting)
                self.didApply(setting)
            } catch is CancellationError {
                return
            } catch {
                self.report(error)
            }
        }
    }

    /// A binding onto one setting. `read` extracts the value from the merged settings,
    /// `fallback` is shown until the device has reported it, and `make` builds the write.
    func binding<Value>(_ read: @escaping (OmniSettings) -> Value?, fallback: Value, debounce: Duration? = nil,
                        _ make: @escaping (Value) -> OmniSetting) -> Binding<Value> {
        Binding(
            get: { read(self.settings) ?? fallback },
            set: { self.set(make($0), debounce: debounce) }
        )
    }

    /// Same, for sliders that want a `Double`.
    func sliderBinding(_ read: @escaping (OmniSettings) -> Int?, fallback: Int, debounce: Duration = .milliseconds(350),
                       _ make: @escaping (Int) -> OmniSetting) -> Binding<Double> {
        Binding(
            get: { Double(read(self.settings) ?? fallback) },
            set: { self.set(make(Int($0.rounded())), debounce: debounce) }
        )
    }

    /// Save-to-flash (`01 09`) so the hub keeps its current settings after a power loss.
    func saveToDevice() {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.device.saveToDevice()
                self.notify(String(localized: "Saved to the GameHub"))
            } catch {
                self.report(error)
            }
        }
    }
}
