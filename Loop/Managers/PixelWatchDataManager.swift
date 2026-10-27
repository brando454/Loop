//
//  PixelWatchDataManager.swift
//  Loop
//
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//

import CoreBluetooth
import Foundation
import HealthKit
import LoopCore
import LoopKit

/// Streams Loop status to a BLE-connected Wear OS watch, and accepts Pre-Meal and
/// named-preset override commands from that watch.
///
/// The phone publishes one GATT service. The watch (already bonded to the iPhone
/// for ANCS) subscribes to the context characteristic and writes a binary plist
/// to the command characteristic. Notifications are chunked:
///
///     byte 0: flags (bit 0 = first chunk, bit 1 = last chunk)
///     byte 1: sequence number within the message
///     rest:   payload
///
/// Envelope version stays `1`. A command result is its own plist (`ack`), then a
/// fresh snapshot. Carb and bolus commands are rejected. Schema: `docs/pixel-watch-protocol.md`.
final class PixelWatchDataManager: NSObject {

    /// Must match the LOOP_* UUIDs on the watch side (watch-iphone-bridge / Loop Wrist).
    static let serviceUUID = CBUUID(string: "354E12EF-6EA4-4255-B054-9D2A113E2C8D")
    static let contextUUID = CBUUID(string: "219E7627-1F0C-4D0C-951F-FDC44514B868")
    static let commandUUID = CBUUID(string: "C5D8A1E4-7B32-4F9A-8E16-0A4D5C7B9E21")

    /// Notify-only and encryption-required. An unbonded peer cannot subscribe.
    static let contextProperties: CBCharacteristicProperties = [.notifyEncryptionRequired]

    /// No read and no write permission. The value is delivered only as notifications.
    static let contextPermissions: CBAttributePermissions = []

    /// Write With Response, and only on an encrypted link. The bond is the same one the notify path uses.
    static let commandProperties: CBCharacteristicProperties = [.write, .writeEncryptionRequired]

    /// `writeable` is required for Core Bluetooth to accept the characteristic.
    /// `writeEncryptionRequired` is what rejects an unencrypted write. Omitting `writeable`
    /// makes `didAdd` fail and takes the notify characteristic down with the service.
    static let commandPermissions: CBAttributePermissions = [.writeable, .writeEncryptionRequired]

    private unowned let deviceManager: DeviceDataManager
    private unowned let watchManager: WatchDataManager

    private let log = DiagnosticLog(category: "PixelWatchDataManager")
    private let queue = DispatchQueue(label: "com.loopkit.Loop.PixelWatchDataManager.queue")

    private var peripheralManager: CBPeripheralManager!
    private var contextCharacteristic: CBMutableCharacteristic?
    private var commandCharacteristic: CBMutableCharacteristic?
    /// Service handed back by state restoration. Kept so we can remove it even if `peripheral.services` is still empty.
    private var restoredService: CBService?
    private var servicesPendingRemoval = 0
    private var republishAfterRemoval = false
    /// The service currently passed to `add`. Characteristics are adopted only after `didAdd` succeeds.
    private var pendingPublish: PendingPublish?
    private var didFallBackToContextOnly = false

    /// Ack chunks are always drained before snapshot chunks. A new ack drops any snapshot bytes still waiting.
    private var pendingAckChunks: [Data] = []
    private var pendingSnapshotChunks: [Data] = []

    /// One snapshot build at a time. A newer request is remembered and runs after this one is sent,
    /// so a burst of loop updates cannot discard every payload before the watch sees one.
    private var snapshotBuildInFlight = false
    private var snapshotBuildQueued = false

    private var processor = PixelWatchCommandProcessor(receipts: [], testMode: false)

    /// Avoid logging the same oversized-payload fallback on every loop update.
    private var loggedOversizedSnapshot = false

    private let historicalGlucoseInterval = TimeInterval(hours: 3)

    init(deviceManager: DeviceDataManager, watchManager: WatchDataManager) {
        self.deviceManager = deviceManager
        self.watchManager = watchManager

        super.init()

        do {
            let receipts = try PixelWatchCommandProcessor.receipts(from: .standard)
            processor.receipts = receipts
        } catch {
            log.error("Could not read Pixel Watch command receipts: %{public}@", String(describing: error))
        }
        processor.testMode = UserDefaults.standard.bool(forKey: PixelWatchCommandProcessor.userDefaultsTestModeKey)

        NotificationCenter.default.addObserver(self, selector: #selector(loopDataUpdated(_:)), name: .LoopDataUpdated, object: deviceManager.loopManager)

        peripheralManager = CBPeripheralManager(
            delegate: self,
            queue: queue,
            options: [CBPeripheralManagerOptionRestoreIdentifierKey: "com.loopkit.Loop.PixelWatchDataManager"]
        )
    }

    @objc private func loopDataUpdated(_ note: Notification) {
        sendContextIfNeeded()
    }

    private func sendContextIfNeeded() {
        queue.async {
            self.startSnapshotOnQueue()
        }
    }

    /// Runs on `queue`.
    private func startSnapshotOnQueue() {
        guard let characteristic = contextCharacteristic,
              let centrals = characteristic.subscribedCentrals,
              !centrals.isEmpty
        else {
            return
        }

        if snapshotBuildInFlight {
            snapshotBuildQueued = true
            return
        }
        snapshotBuildInFlight = true

        watchManager.createWatchContext { context in
            let settings = self.deviceManager.loopManager.settings
            let pumpDataDate = self.deviceManager.doseStore.lastAddedPumpData
            let defaultCarbAbsorption = self.deviceManager.carbStore.defaultAbsorptionTimes.medium
            self.makeSnapshot(
                for: context,
                settings: settings,
                pumpDataDate: pumpDataDate,
                defaultCarbAbsorption: defaultCarbAbsorption
            ) { snapshot in
                self.queue.async {
                    self.snapshotBuildInFlight = false
                    self.enqueue(snapshot)
                    if self.snapshotBuildQueued {
                        self.snapshotBuildQueued = false
                        self.startSnapshotOnQueue()
                    }
                }
            }
        }
    }

    private func makeSnapshot(
        for context: WatchContext,
        settings: LoopSettings,
        pumpDataDate: Date,
        defaultCarbAbsorption: TimeInterval,
        completion: @escaping (PixelWatchActionsSnapshot) -> Void
    ) {
        let start = Date(timeIntervalSinceNow: -historicalGlucoseInterval)
        deviceManager.glucoseStore.getGlucoseSamples(start: start, end: nil) { result in
            let history: [[Double]]
            if case .success(let samples) = result {
                history = samples.map {
                    [$0.startDate.timeIntervalSince1970, $0.quantity.doubleValue(for: .milligramsPerDeciliter)]
                }
            } else {
                history = []
            }

            completion(PixelWatchActionsSnapshot.make(
                context: context,
                glucoseHistory: history,
                settings: settings,
                pumpDataDate: pumpDataDate,
                defaultCarbAbsorption: defaultCarbAbsorption
            ))
        }
    }

    /// Runs on `queue`. Replaces a snapshot that has not finished. Does not drop a queued ack.
    private func enqueue(_ snapshot: PixelWatchActionsSnapshot) {
        guard let characteristic = contextCharacteristic,
              let centrals = characteristic.subscribedCentrals,
              !centrals.isEmpty,
              let maximumUpdateValueLength = centrals.map({ $0.maximumUpdateValueLength }).min()
        else {
            return
        }
        guard let payload = snapshot.framedPayload(maximumUpdateValueLength: maximumUpdateValueLength) else {
            log.error("Could not serialize context envelope")
            return
        }

        notePayloadSize(payload)

        // The watch resets its reassembly buffer on every first-flagged chunk,
        // so replacing an unfinished snapshot with a newer one is safe.
        pendingSnapshotChunks = payload.chunks
        drainChunks()
    }

    /// Runs on `queue`. An ack is a separate message. Any snapshot bytes not yet sent are dropped
    /// so they cannot land between the ack's chunks, and the next snapshot is built after the ack.
    private func enqueueAck(_ ack: PixelWatchCommandAck) {
        guard let characteristic = contextCharacteristic,
              let centrals = characteristic.subscribedCentrals,
              !centrals.isEmpty,
              let maximumUpdateValueLength = centrals.map({ $0.maximumUpdateValueLength }).min()
        else {
            log.error("Pixel Watch command ack not sent: no subscribed watch")
            return
        }

        do {
            let data = try PropertyListSerialization.data(fromPropertyList: ack.envelope, format: .binary, options: 0)
            let chunks = PixelWatchNotificationFraming.chunks(of: data, maximumUpdateValueLength: maximumUpdateValueLength)
            pendingAckChunks.append(contentsOf: chunks)
            pendingSnapshotChunks.removeAll()
            drainChunks()
        } catch {
            log.error("Could not serialize Pixel Watch command ack: %{public}@", String(describing: error))
        }
    }

    /// Runs on `queue`.
    private func notePayloadSize(_ payload: PixelWatchFramedPayload) {
        let oversized = payload.kind != .full || payload.chunks.count > PixelWatchNotificationFraming.maxChunks
        guard oversized else {
            loggedOversizedSnapshot = false
            return
        }
        guard !loggedOversizedSnapshot else {
            return
        }
        loggedOversizedSnapshot = true
        switch payload.kind {
        case .full:
            log.error("Pixel Watch context envelope exceeds the BLE chunk budget")
        case .presetsOmitted:
            log.default("Pixel Watch actions snapshot omitted presets to fit the BLE notification budget")
        case .actionsOmitted:
            log.error("Pixel Watch actions snapshot omitted to fit the BLE notification budget")
        }
    }

    /// Runs on `queue`. Acks drain completely before any snapshot chunk.
    private func drainChunks() {
        guard let characteristic = contextCharacteristic else {
            return
        }

        while !pendingAckChunks.isEmpty || !pendingSnapshotChunks.isEmpty {
            let sendingAck = !pendingAckChunks.isEmpty
            let chunk = sendingAck ? pendingAckChunks[0] : pendingSnapshotChunks[0]
            guard peripheralManager.updateValue(chunk, for: characteristic, onSubscribedCentrals: nil) else {
                // Transmit queue is full; peripheralManagerIsReady(toUpdateSubscribers:) resumes
                return
            }
            if sendingAck {
                pendingAckChunks.removeFirst()
            } else {
                pendingSnapshotChunks.removeFirst()
            }
        }
    }

    /// Runs on `queue`. GATT success was already sent. Application failures travel in the ack, not as an ATT error,
    /// so the watch stack does not retry the write.
    private func handleAssembledCommand(_ data: Data) {
        let object: Any?
        do {
            object = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        } catch {
            object = nil
            log.error("Pixel Watch command was not a property list: %{public}@", String(describing: error))
        }

        processor.testMode = UserDefaults.standard.bool(forKey: PixelWatchCommandProcessor.userDefaultsTestModeKey)
        var outcome = processor.handle(object, settings: deviceManager.loopManager.settings, now: Date())
        persistReceipts()

        if let effect = outcome.effect {
            var applied = false
            let appliedAt = Date()
            deviceManager.loopManager.mutateSettings { settings in
                applied = PixelWatchOverrideApplicator.apply(effect, to: &settings, at: appliedAt)
            }
            if !applied, let requestId = outcome.ack.requestId {
                outcome.ack = processor.markApplyFailed(requestId: requestId)
                outcome.effect = nil
                persistReceipts()
            }
        }

        logCommand(outcome)
        enqueueAck(outcome.ack)
        // Deferred until this callback returns, so the ack is queued (and sent, if the radio accepts it)
        // before the snapshot that shows the result.
        sendContextIfNeeded()
    }

    private func persistReceipts() {
        do {
            try PixelWatchCommandProcessor.store(processor.receipts, in: .standard)
        } catch {
            log.error("Could not store Pixel Watch command receipts: %{public}@", String(describing: error))
        }
    }

    private func logCommand(_ outcome: PixelWatchCommandOutcome) {
        let extra = "duplicate=\(outcome.duplicate) testMode=\(outcome.testMode) presetId=\(outcome.presetId ?? "") applied=\(outcome.effect != nil)"
        log.default(
            "Pixel Watch command cmd=%{public}@ requestId=%{public}@ status=%{public}@ reason=%{public}@ %{public}@",
            outcome.commandName ?? "",
            outcome.ack.requestId?.uuidString ?? "",
            outcome.ack.status.rawValue,
            outcome.ack.reason ?? "",
            extra
        )
    }

    /// Runs on `queue`. A characteristic cannot be added to a service that is already published.
    /// The working notify characteristic stays in place until a replacement `didAdd` succeeds.
    private func ensureService(on peripheral: CBPeripheralManager) {
        let published = peripheral.services?.filter { $0.uuid == Self.serviceUUID } ?? []
        guard let service = published.first ?? restoredService else {
            addService(includingCommand: true, to: peripheral)
            return
        }

        adopt(service)
        if !published.isEmpty && contextCharacteristic != nil && Self.commandCharacteristicIsUsable(on: service) {
            log.default("Pixel Watch service already published with context and command characteristics")
            return
        }

        let toRemove = published.isEmpty ? [service] : published
        log.default("Pixel Watch service is missing a usable command characteristic; removing it before republish. The watch must reconnect.")
        republishAfterRemoval = true
        servicesPendingRemoval = toRemove.count
        toRemove.forEach { peripheral.remove($0) }
    }

    /// A command characteristic Core Bluetooth will keep published. Missing `writeable` is the PR #2 bug:
    /// the service is rejected, or the watch cannot use the connection.
    private static func commandCharacteristicIsUsable(on service: CBService) -> Bool {
        guard let command = service.characteristics?.first(where: { $0.uuid == Self.commandUUID }) as? CBMutableCharacteristic else {
            return false
        }
        let properties = command.properties
        guard properties.contains(.write), properties.contains(.writeEncryptionRequired) else {
            return false
        }
        let permissions = command.permissions
        if permissions.isEmpty {
            // Some restores do not report permissions. Properties already match, so do not republish every launch.
            return true
        }
        return permissions.contains(.writeable) && permissions.contains(.writeEncryptionRequired)
    }

    private func adopt(_ service: CBService) {
        if let context = service.characteristics?.first(where: { $0.uuid == Self.contextUUID }) as? CBMutableCharacteristic {
            contextCharacteristic = context
        }
        if let command = service.characteristics?.first(where: { $0.uuid == Self.commandUUID }) as? CBMutableCharacteristic {
            commandCharacteristic = command
        }
    }

    /// Builds a new service. Does not replace `contextCharacteristic` until Core Bluetooth accepts it.
    private func addService(includingCommand: Bool, to peripheral: CBPeripheralManager) {
        let context = CBMutableCharacteristic(
            type: Self.contextUUID,
            properties: Self.contextProperties,
            value: nil,
            permissions: Self.contextPermissions
        )
        var characteristics = [context]
        var command: CBMutableCharacteristic?
        if includingCommand {
            let writable = CBMutableCharacteristic(
                type: Self.commandUUID,
                properties: Self.commandProperties,
                value: nil,
                permissions: Self.commandPermissions
            )
            command = writable
            characteristics.append(writable)
        }
        let service = CBMutableService(type: Self.serviceUUID, primary: true)
        service.characteristics = characteristics
        pendingPublish = PendingPublish(service: service, context: context, command: command)
        peripheral.add(service)
    }
}

private struct PendingPublish {
    var service: CBMutableService
    var context: CBMutableCharacteristic
    var command: CBMutableCharacteristic?
}

extension PixelWatchDataManager: CBPeripheralManagerDelegate {
    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        switch peripheral.state {
        case .poweredOn:
            ensureService(on: peripheral)
        default:
            break
        }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, willRestoreState dict: [String: Any]) {
        guard let service = Self.restoredServices(from: dict).first(where: { $0.uuid == Self.serviceUUID }) else {
            return
        }
        restoredService = service
        adopt(service)
        if commandCharacteristic == nil {
            log.default("Restored Pixel Watch service has no command characteristic")
        }
    }

    private static func restoredServices(from dict: [String: Any]) -> [CBService] {
        if let services = dict[CBPeripheralManagerRestoredStateServicesKey] as? [CBMutableService] {
            return services
        }
        if let services = dict[CBPeripheralManagerRestoredStateServicesKey] as? [CBService] {
            return services
        }
        return []
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        let pending = pendingPublish
        pendingPublish = nil
        guard service.uuid == Self.serviceUUID else {
            pendingPublish = pending
            return
        }
        if let error = error {
            log.error("Could not publish Loop context service: %{public}@", String(describing: error))
            let failedWithCommand = pending?.command != nil
            if failedWithCommand && !didFallBackToContextOnly {
                didFallBackToContextOnly = true
                log.error("Publishing the Pixel Watch service without the command characteristic so snapshots can continue")
                addService(includingCommand: false, to: peripheral)
            }
            return
        }

        if let pending = pending {
            contextCharacteristic = pending.context
            commandCharacteristic = pending.command
        }
        restoredService = nil
        if commandCharacteristic != nil {
            log.default("Published Pixel Watch service with context and command characteristics")
        } else {
            log.default("Published Pixel Watch service with the context characteristic only")
        }
        sendContextIfNeeded()
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didRemove service: CBService, error: Error?) {
        guard service.uuid == Self.serviceUUID, servicesPendingRemoval > 0 else {
            return
        }
        servicesPendingRemoval -= 1
        if let error = error {
            log.error("Could not remove the restored Pixel Watch service: %{public}@", String(describing: error))
        } else {
            // Removal succeeded, so the previous characteristic is no longer published.
            contextCharacteristic = nil
            commandCharacteristic = nil
            restoredService = nil
        }
        guard servicesPendingRemoval == 0, republishAfterRemoval else {
            return
        }
        republishAfterRemoval = false
        addService(includingCommand: true, to: peripheral)
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didSubscribeTo characteristic: CBCharacteristic) {
        guard characteristic.uuid == Self.contextUUID else {
            return
        }
        if let mutable = characteristic as? CBMutableCharacteristic {
            contextCharacteristic = mutable
        }
        log.default("Watch subscribed to Loop context; sending current state")
        sendContextIfNeeded()
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveRead request: CBATTRequest) {
        peripheral.respond(to: request, withResult: .readNotPermitted)
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        guard !requests.isEmpty else {
            return
        }

        if requests.contains(where: { $0.characteristic.uuid != Self.commandUUID }) {
            for request in requests {
                peripheral.respond(to: request, withResult: .writeNotPermitted)
            }
            log.error("Pixel Watch write rejected: characteristic does not accept commands")
            return
        }

        switch PixelWatchWriteAssembler.assemble(requests.map { ($0.offset, $0.value ?? Data()) }) {
        case .failure(let failure):
            let code: CBATTError.Code = failure == .gap ? .invalidOffset : .invalidAttributeValueLength
            for request in requests {
                peripheral.respond(to: request, withResult: code)
            }
            log.error("Pixel Watch write rejected before decode: %{public}@", String(describing: failure))
        case .success(let data):
            for request in requests {
                peripheral.respond(to: request, withResult: .success)
            }
            handleAssembledCommand(data)
        }
    }

    func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) {
        drainChunks()
    }
}
