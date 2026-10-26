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

    /// Encryption required, with no unencrypted write permission. The stack rejects a write that is not authenticated.
    static let commandPermissions: CBAttributePermissions = [.writeEncryptionRequired]

    private unowned let deviceManager: DeviceDataManager
    private unowned let watchManager: WatchDataManager

    private let log = DiagnosticLog(category: "PixelWatchDataManager")
    private let queue = DispatchQueue(label: "com.loopkit.Loop.PixelWatchDataManager.queue")

    private var peripheralManager: CBPeripheralManager!
    private var contextCharacteristic: CBMutableCharacteristic?
    private var commandCharacteristic: CBMutableCharacteristic?
    private var servicesPendingRemoval = 0

    /// Ack chunks are always drained before snapshot chunks. A new ack drops any snapshot bytes still waiting.
    private var pendingAckChunks: [Data] = []
    private var pendingSnapshotChunks: [Data] = []

    /// Bumped each time a snapshot is requested. An older fetch must not overwrite a newer one.
    private var snapshotGeneration: UInt64 = 0

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

        snapshotGeneration &+= 1
        let generation = snapshotGeneration

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
                    guard generation == self.snapshotGeneration else {
                        return
                    }
                    self.enqueue(snapshot)
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

    private func ensureService(on peripheral: CBPeripheralManager) {
        if contextCharacteristic != nil && commandCharacteristic != nil {
            return
        }

        let published = peripheral.services?.filter { $0.uuid == Self.serviceUUID } ?? []
        let restoredIncomplete = contextCharacteristic != nil || commandCharacteristic != nil || !published.isEmpty
        guard restoredIncomplete else {
            addService(to: peripheral)
            return
        }

        log.default("Pixel Watch service is missing the command characteristic; republishing. The watch must reconnect.")
        contextCharacteristic = nil
        commandCharacteristic = nil
        guard !published.isEmpty else {
            addService(to: peripheral)
            return
        }
        servicesPendingRemoval = published.count
        published.forEach { peripheral.remove($0) }
    }

    private func addService(to peripheral: CBPeripheralManager) {
        let context = CBMutableCharacteristic(
            type: Self.contextUUID,
            properties: Self.contextProperties,
            value: nil,
            permissions: Self.contextPermissions
        )
        let command = CBMutableCharacteristic(
            type: Self.commandUUID,
            properties: Self.commandProperties,
            value: nil,
            permissions: Self.commandPermissions
        )
        let service = CBMutableService(type: Self.serviceUUID, primary: true)
        service.characteristics = [context, command]
        contextCharacteristic = context
        commandCharacteristic = command
        peripheral.add(service)
    }
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
        guard let services = dict[CBPeripheralManagerRestoredStateServicesKey] as? [CBMutableService],
              let service = services.first(where: { $0.uuid == Self.serviceUUID })
        else {
            return
        }
        contextCharacteristic = service.characteristics?.first(where: { $0.uuid == Self.contextUUID }) as? CBMutableCharacteristic
        commandCharacteristic = service.characteristics?.first(where: { $0.uuid == Self.commandUUID }) as? CBMutableCharacteristic
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        if let error = error {
            log.error("Could not publish Loop context service: %{public}@", String(describing: error))
        }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didRemove service: CBService, error: Error?) {
        guard service.uuid == Self.serviceUUID, servicesPendingRemoval > 0 else {
            return
        }
        servicesPendingRemoval -= 1
        if let error = error {
            log.error("Could not remove the restored Pixel Watch service: %{public}@", String(describing: error))
        }
        guard servicesPendingRemoval == 0 else {
            return
        }
        addService(to: peripheral)
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didSubscribeTo characteristic: CBCharacteristic) {
        guard characteristic.uuid == Self.contextUUID else {
            return
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
