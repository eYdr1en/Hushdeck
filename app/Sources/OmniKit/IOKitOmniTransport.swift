import Foundation
import IOKit
import IOKit.hid

/// Real-hardware transport over IOHIDManager.
///
/// - Matches only vendor 0x1038, product 0x2290, and only the vendor collections (device usage
///   page 0xFFC0 or 0xFF00). The refused PIDs 0x2291 / 0x2296 / 0x2297 are never matched, and
///   `deviceMatched` rejects anything that isn't exactly the GameHub on interface 3.
/// - Output reports go out with `IOHIDDeviceSetReport(kIOHIDReportTypeOutput)` (a control
///   SET_REPORT, since the hub has no interrupt OUT endpoint). Feature reads/writes use
///   `IOHIDDeviceGetReport` / `SetReport(kIOHIDReportTypeFeature)`.
/// - Input reports are classified by report ID using the device's element tree: a report ID whose
///   input elements live under the 0xFF00 application collection is an event.
/// - All IOKit callbacks run on one private serial queue; blocking transfers run on another.
///
/// Permissions: vendor-defined usage pages don't need Input Monitoring (TCC only gates keyboard-
/// style devices), and a non-sandboxed app needs no entitlements. A sandboxed build would need
/// `com.apple.security.device.usb`. If `IOHIDManagerOpen` ever returns `kIOReturnNotPermitted`
/// (0xE00002E2), `start()` throws `OmniError.transportFailure` with that code.
public final class IOKitOmniTransport: OmniTransport, @unchecked Sendable {
    private struct DeviceRef: @unchecked Sendable {
        let device: IOHIDDevice
    }

    private let callbackQueue = DispatchQueue(label: "OmniKit.IOKitOmniTransport.callbacks")
    private let ioQueue = DispatchQueue(label: "OmniKit.IOKitOmniTransport.io")
    private let lock = NSLock()
    private let broadcaster = OmniBroadcaster<OmniTransportEvent>()
    private let mailbox = OmniReplyMailbox()

    // Guarded by `lock`.
    private var manager: IOHIDManager?
    private var commandDevice: IOHIDDevice?
    private var attachedHub: OmniHubInfo?
    private var collections: [UInt8: OmniReportCollection] = [:]
    private var cancelWaiter: (id: UUID, continuation: CheckedContinuation<Void, Never>)?
    private var retainedContext: Unmanaged<IOKitOmniTransport>?

    public init() {}

    /// `true` while a GameHub command collection is attached.
    public var isHubAttached: Bool { lock.withLock { commandDevice != nil } }
    public var hubInfo: OmniHubInfo? { lock.withLock { attachedHub } }
    public var isRunning: Bool { lock.withLock { manager != nil } }

    // MARK: Lifecycle

    public func start() async throws {
        // IOHIDManagerActivate delivers already-attached devices synchronously on this thread,
        // and deviceMatched takes `lock`, so activation must happen after the lock is released.
        let toActivate: IOHIDManager? = try lock.withLock {
            guard manager == nil else { return nil }
            let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
            let matches: [[String: Int]] = [OmniUSB.commandUsagePage, OmniUSB.eventUsagePage].map {
                [kIOHIDVendorIDKey: OmniUSB.vendorID, kIOHIDProductIDKey: OmniUSB.gameHubProductID, kIOHIDDeviceUsagePageKey: $0]
            }
            IOHIDManagerSetDeviceMatchingMultiple(manager, matches as CFArray)

            let context = Unmanaged.passRetained(self)
            let raw = context.toOpaque()
            IOHIDManagerRegisterDeviceMatchingCallback(manager, { context, _, _, device in
                guard let context else { return }
                Unmanaged<IOKitOmniTransport>.fromOpaque(context).takeUnretainedValue().deviceMatched(device)
            }, raw)
            IOHIDManagerRegisterDeviceRemovalCallback(manager, { context, _, _, device in
                guard let context else { return }
                Unmanaged<IOKitOmniTransport>.fromOpaque(context).takeUnretainedValue().deviceRemoved(device)
            }, raw)
            IOHIDManagerRegisterInputReportCallback(manager, { context, _, sender, _, reportID, report, length in
                guard let context else { return }
                Unmanaged<IOKitOmniTransport>.fromOpaque(context).takeUnretainedValue()
                    .inputReport(sender: sender, reportID: reportID, report: report, length: length)
            }, raw)
            IOHIDManagerSetDispatchQueue(manager, callbackQueue)
            IOHIDManagerSetCancelHandler(manager) { [self] in managerCancelled() }

            let opened = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
            guard opened == kIOReturnSuccess else {
                // Not activated yet, so nothing has been delivered; undo and report.
                context.release()
                throw OmniError.transportFailure(operation: "IOHIDManagerOpen", code: opened)
            }
            self.manager = manager
            self.retainedContext = context
            return manager
        }
        if let toActivate { IOHIDManagerActivate(toActivate) }
    }

    public func stop() async {
        let manager: IOHIDManager? = lock.withLock {
            defer { self.manager = nil }
            return self.manager
        }
        guard let manager else { return }
        mailbox.failAll(OmniError.transportStopped)

        let waiterID = UUID()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.withLock { cancelWaiter = (waiterID, continuation) }
            let handle = DeviceManagerRef(manager: manager)
            callbackQueue.async {
                IOHIDManagerClose(handle.manager, IOOptionBits(kIOHIDOptionsTypeNone))
                IOHIDManagerCancel(handle.manager)
            }
            // Never hang: if the cancel handler doesn't run within 2 s, carry on.
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [weak self] in
                self?.resumeCancelWaiter(only: waiterID)
            }
        }

        let hadHub: Bool = lock.withLock {
            defer {
                commandDevice = nil
                attachedHub = nil
                collections = [:]
            }
            return commandDevice != nil
        }
        if hadHub { broadcaster.yield(.disconnected) }
    }

    public func events() -> AsyncStream<OmniTransportEvent> {
        let initial: [OmniTransportEvent] = lock.withLock { attachedHub.map { [.connected($0)] } ?? [] }
        return broadcaster.subscribe(initial: initial)
    }

    // MARK: I/O

    public func sendOutputReport(_ report: OmniOutputReport) async throws {
        let bytes = report.bytes
        try OmniSafety.validateOutput(bytes) // Last gate before the bytes leave the process.
        let ref = try currentDevice()
        mailbox.reset()
        try await perform("SET_REPORT(output)") {
            bytes.withUnsafeBufferPointer { buffer in
                IOHIDDeviceSetReport(ref.device, kIOHIDReportTypeOutput, CFIndex(bytes[0]), buffer.baseAddress!, buffer.count)
            }
        }
    }

    public func receiveInputReport(timeout: Duration, matching: @escaping @Sendable (OmniInputReport) -> Bool) async throws -> OmniInputReport {
        _ = try currentDevice()
        return try await mailbox.receive(timeout: timeout, description: "input report", matching: matching)
    }

    public func getFeatureReport(reportID: UInt8, length: Int) async throws -> [UInt8] {
        let ref = try currentDevice()
        return try await withCheckedThrowingContinuation { continuation in
            ioQueue.async {
                var buffer = [UInt8](repeating: 0, count: length)
                buffer[0] = reportID
                var size = CFIndex(length)
                let result = IOHIDDeviceGetReport(ref.device, kIOHIDReportTypeFeature, CFIndex(reportID), &buffer, &size)
                if result == kIOReturnSuccess {
                    continuation.resume(returning: Array(buffer.prefix(max(0, min(size, length)))))
                } else {
                    continuation.resume(throwing: OmniError.transportFailure(operation: "GET_REPORT(feature)", code: result))
                }
            }
        }
    }

    public func setFeatureReport(_ report: OmniFeatureReport) async throws {
        let bytes = report.bytes
        try OmniSafety.validateFeatureWrite(bytes) // Last gate before the bytes leave the process.
        let ref = try currentDevice()
        try await perform("SET_REPORT(feature)") {
            bytes.withUnsafeBufferPointer { buffer in
                IOHIDDeviceSetReport(ref.device, kIOHIDReportTypeFeature, CFIndex(bytes[0]), buffer.baseAddress!, buffer.count)
            }
        }
    }

    // MARK: Callbacks (callbackQueue)

    private func deviceMatched(_ device: IOHIDDevice) {
        guard let vendor = Self.int(device, kIOHIDVendorIDKey), let product = Self.int(device, kIOHIDProductIDKey),
              OmniUSB.isSupported(vendorID: vendor, productID: product) else { return }
        if let interface = Self.interfaceNumber(device), interface != OmniUSB.hidInterface { return }
        let pages = Self.usagePages(device)
        guard pages.contains(OmniUSB.commandUsagePage) || pages.contains(OmniUSB.eventUsagePage) else { return }
        let found = Self.reportCollections(device)

        let announce: OmniHubInfo? = lock.withLock {
            for (id, collection) in found {
                if let existing = collections[id], existing != collection {
                    collections[id] = .unknown
                } else {
                    collections[id] = collection
                }
            }
            guard pages.contains(OmniUSB.commandUsagePage), commandDevice == nil else { return nil }
            commandDevice = device
            let info = OmniHubInfo(vendorID: vendor, productID: product,
                                   productName: Self.string(device, kIOHIDProductKey),
                                   usbSerialNumber: Self.string(device, kIOHIDSerialNumberKey),
                                   releaseNumber: Self.int(device, kIOHIDVersionNumberKey),
                                   locationID: Self.int(device, kIOHIDLocationIDKey))
            attachedHub = info
            return info
        }
        if let announce { broadcaster.yield(.connected(announce)) }
    }

    private func deviceRemoved(_ device: IOHIDDevice) {
        let wasHub: Bool = lock.withLock {
            guard let current = commandDevice, CFEqual(current, device) else { return false }
            commandDevice = nil
            attachedHub = nil
            collections = [:]
            return true
        }
        guard wasHub else { return }
        mailbox.failAll(OmniError.notConnected)
        broadcaster.yield(.disconnected)
    }

    private func inputReport(sender: UnsafeMutableRawPointer?, reportID: UInt32, report: UnsafeMutablePointer<UInt8>, length: CFIndex) {
        guard length > 0 else { return }
        var bytes = Array(UnsafeBufferPointer(start: report, count: length))
        let id = UInt8(truncatingIfNeeded: reportID)
        if id != 0, bytes.first != id { bytes.insert(id, at: 0) }
        let collection: OmniReportCollection? = lock.withLock {
            guard let device = commandDevice else { return nil }
            // Only accept reports from the hub we're attached to.
            if let sender, sender != Unmanaged.passUnretained(device).toOpaque() { return nil }
            return collections[id] ?? .unknown
        }
        guard let collection else { return }
        let input = OmniInputReport(bytes: bytes, collection: collection)
        if collection != .events { mailbox.deliver(input) }
        broadcaster.yield(.inputReport(input))
    }

    private func managerCancelled() {
        let context: Unmanaged<IOKitOmniTransport>? = lock.withLock {
            defer { retainedContext = nil }
            return retainedContext
        }
        resumeCancelWaiter()
        context?.release()
    }

    private func resumeCancelWaiter(only id: UUID? = nil) {
        let waiter: CheckedContinuation<Void, Never>? = lock.withLock {
            guard let current = cancelWaiter, id == nil || current.id == id else { return nil }
            cancelWaiter = nil
            return current.continuation
        }
        waiter?.resume()
    }

    // MARK: Helpers

    private struct DeviceManagerRef: @unchecked Sendable {
        let manager: IOHIDManager
    }

    private func currentDevice() throws -> DeviceRef {
        try lock.withLock {
            guard manager != nil else { throw OmniError.transportStopped }
            guard let device = commandDevice else { throw OmniError.notConnected }
            return DeviceRef(device: device)
        }
    }

    private func perform(_ operation: String, _ body: @escaping @Sendable () -> IOReturn) async throws {
        let result: IOReturn = await withCheckedContinuation { continuation in
            ioQueue.async { continuation.resume(returning: body()) }
        }
        guard result == kIOReturnSuccess else { throw OmniError.transportFailure(operation: operation, code: result) }
    }

    private static func property(_ device: IOHIDDevice, _ key: String) -> AnyObject? {
        IOHIDDeviceGetProperty(device, key as CFString)
    }

    private static func int(_ device: IOHIDDevice, _ key: String) -> Int? {
        (property(device, key) as? NSNumber)?.intValue
    }

    private static func string(_ device: IOHIDDevice, _ key: String) -> String? {
        property(device, key) as? String
    }

    private static func interfaceNumber(_ device: IOHIDDevice) -> Int? {
        let service = IOHIDDeviceGetService(device)
        guard service != IO_OBJECT_NULL else { return nil }
        let value = IORegistryEntrySearchCFProperty(service, kIOServicePlane, "bInterfaceNumber" as CFString, kCFAllocatorDefault,
                                                    IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents))
        return (value as? NSNumber)?.intValue
    }

    private static func usagePages(_ device: IOHIDDevice) -> Set<Int> {
        var pages = Set<Int>()
        if let primary = int(device, kIOHIDPrimaryUsagePageKey) { pages.insert(primary) }
        if let pairs = property(device, kIOHIDDeviceUsagePairsKey) as? [[String: Any]] {
            for pair in pairs {
                if let page = (pair[kIOHIDDeviceUsagePageKey] as? NSNumber)?.intValue { pages.insert(page) }
            }
        }
        return pages
    }

    /// Maps each input report ID to the vendor collection its elements belong to.
    private static func reportCollections(_ device: IOHIDDevice) -> [UInt8: OmniReportCollection] {
        guard let elements = IOHIDDeviceCopyMatchingElements(device, nil, IOOptionBits(kIOHIDOptionsTypeNone)) as? [IOHIDElement] else {
            return [:]
        }
        let inputTypes: Set<UInt32> = [kIOHIDElementTypeInput_Misc.rawValue, kIOHIDElementTypeInput_Button.rawValue,
                                       kIOHIDElementTypeInput_Axis.rawValue, kIOHIDElementTypeInput_ScanCodes.rawValue]
        var pagesByReport: [UInt8: Set<Int>] = [:]
        for element in elements where inputTypes.contains(IOHIDElementGetType(element).rawValue) {
            var page: Int?
            var cursor: IOHIDElement? = element
            while let current = cursor {
                if IOHIDElementGetType(current) == kIOHIDElementTypeCollection,
                   IOHIDElementGetCollectionType(current) == kIOHIDElementCollectionTypeApplication {
                    page = Int(IOHIDElementGetUsagePage(current))
                }
                cursor = IOHIDElementGetParent(current)
            }
            guard let page else { continue }
            pagesByReport[UInt8(truncatingIfNeeded: IOHIDElementGetReportID(element)), default: []].insert(page)
        }
        return pagesByReport.mapValues { pages in
            switch pages {
            case [OmniUSB.commandUsagePage]: .commands
            case [OmniUSB.eventUsagePage]: .events
            default: .unknown
            }
        }
    }
}
