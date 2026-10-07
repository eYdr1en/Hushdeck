import AppKit
import IOKit
import IOKit.usb

/// Calls `onChange` when the Mac wakes or a USB device is plugged in or removed, so a
/// receiver that just (re)appeared shows up without waiting for the next poll.
/// It only watches the IORegistry; it never opens a device.
@MainActor
final class SystemEventsMonitor {
    private var observers: [NSObjectProtocol] = []
    private var usb: USBObservation?

    func start(_ onChange: @escaping @MainActor () -> Void) {
        stop()
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { onChange() }
            })
        }
        usb = USBObservation(onChange)
    }

    func stop() {
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        observers = []
        usb = nil
    }
}

/// IOKit matching notifications for IOUSBHostDevice arrival/termination, delivered on
/// the main run loop.
private final class USBObservation {
    private let port: IONotificationPortRef
    private var iterators: [io_iterator_t] = []
    private let onChange: @MainActor () -> Void

    @MainActor
    init?(_ onChange: @escaping @MainActor () -> Void) {
        guard let port = IONotificationPortCreate(kIOMainPortDefault) else { return nil }
        self.port = port
        self.onChange = onChange
        IONotificationPortSetDispatchQueue(port, .main)

        let callback: IOServiceMatchingCallback = { context, iterator in
            guard let context else { return }
            let observation = Unmanaged<USBObservation>.fromOpaque(context).takeUnretainedValue()
            // Draining re-arms the notification.
            if USBObservation.drain(iterator) {
                MainActor.assumeIsolated { observation.onChange() }
            }
        }
        let context = Unmanaged.passUnretained(self).toOpaque()
        for type in [kIOFirstMatchNotification, kIOTerminatedNotification] {
            var iterator: io_iterator_t = 0
            guard let matching = IOServiceMatching("IOUSBHostDevice"),
                  IOServiceAddMatchingNotification(port, type, matching, callback, context, &iterator) == KERN_SUCCESS
            else { continue }
            Self.drain(iterator) // the initial inventory isn't a change
            iterators.append(iterator)
        }
    }

    @discardableResult
    private static func drain(_ iterator: io_iterator_t) -> Bool {
        var changed = false
        while case let service = IOIteratorNext(iterator), service != 0 {
            changed = true
            IOObjectRelease(service)
        }
        return changed
    }

    deinit {
        iterators.forEach { IOObjectRelease($0) }
        IONotificationPortDestroy(port)
    }
}
