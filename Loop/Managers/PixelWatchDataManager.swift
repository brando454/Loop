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

/// Streams the same status payload the Apple Watch receives to a BLE-connected
/// Wear OS watch, plus a read-only actions snapshot (`act`) the watch can use
/// to draw Pre-Meal, Workout, Carbs, and Bolus screens. The phone publishes one
/// GATT service; the watch (already bonded to the iPhone for ANCS) subscribes
/// to the context characteristic and receives a binary-plist envelope, chunked
/// to fit notification payloads:
///
///     byte 0: flags (bit 0 = first chunk, bit 1 = last chunk)
///     byte 1: sequence number within the message
///     rest:   payload
///
/// Envelope version stays `1`: `v`, `ctx` (WatchContext, minus `cgmManagerState`),
/// and `hg` (three hours of glucose) are unchanged. Actions data is an extra key.
/// This manager does not accept commands. There is no write characteristic.
/// Schema: `docs/pixel-watch-protocol.md`.
final class PixelWatchDataManager: NSObject {

    /// Must match the LOOP_* UUIDs on the watch side (watch-iphone-bridge).
    static let serviceUUID = CBUUID(string: "354E12EF-6EA4-4255-B054-9D2A113E2C8D")
    static let contextUUID = CBUUID(string: "219E7627-1F0C-4D0C-951F-FDC44514B868")

    /// Notify-only and encryption-required. An unbonded peer cannot subscribe, and nobody can write.
    static let contextProperties: CBCharacteristicProperties = [.notifyEncryptionRequired]

    /// No read and no write permission. The value is delivered only as notifications.
    static let contextPermissions: CBAttributePermissions = []

    private unowned let deviceManager: DeviceDataManager
    private unowned let watchManager: WatchDataManager

    private let log = DiagnosticLog(category: "PixelWatchDataManager")
    private let queue = DispatchQueue(label: "com.loopkit.Loop.PixelWatchDataManager.queue")

    private var peripheralManager: CBPeripheralManager!
    private var contextCharacteristic: CBMutableCharacteristic?

    /// Chunks of the in-flight message; replaced whenever a newer context arrives.
    private var pendingChunks: [Data] = []

    /// Avoid logging the same oversized-payload fallback on every loop update.
    private var loggedOversizedSnapshot = false

    private let historicalGlucoseInterval = TimeInterval(hours: 3)

    init(deviceManager: DeviceDataManager, watchManager: WatchDataManager) {
        self.deviceManager = deviceManager
        self.watchManager = watchManager

        super.init()

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
        guard let characteristic = contextCharacteristic,
              let centrals = characteristic.subscribedCentrals,
              !centrals.isEmpty
        else {
            return
        }

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

    /// Runs on `queue`.
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
        // so replacing an unfinished message with a newer one is safe.
        pendingChunks = payload.chunks
        drainChunks()
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

    /// Runs on `queue`.
    private func drainChunks() {
        guard let characteristic = contextCharacteristic else {
            return
        }

        while let chunk = pendingChunks.first {
            guard peripheralManager.updateValue(chunk, for: characteristic, onSubscribedCentrals: nil) else {
                // Transmit queue is full; peripheralManagerIsReady(toUpdateSubscribers:) resumes
                return
            }
            pendingChunks.removeFirst()
        }
    }
}

extension PixelWatchDataManager: CBPeripheralManagerDelegate {
    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        switch peripheral.state {
        case .poweredOn:
            if contextCharacteristic == nil {
                // Notify-only, encryption required: only the bonded watch can subscribe
                let characteristic = CBMutableCharacteristic(
                    type: Self.contextUUID,
                    properties: Self.contextProperties,
                    value: nil,
                    permissions: Self.contextPermissions
                )
                let service = CBMutableService(type: Self.serviceUUID, primary: true)
                service.characteristics = [characteristic]
                contextCharacteristic = characteristic
                peripheral.add(service)
            }
        default:
            break
        }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, willRestoreState dict: [String: Any]) {
        if let services = dict[CBPeripheralManagerRestoredStateServicesKey] as? [CBMutableService],
           let service = services.first(where: { $0.uuid == Self.serviceUUID }),
           let characteristic = service.characteristics?.first(where: { $0.uuid == Self.contextUUID }) as? CBMutableCharacteristic
        {
            contextCharacteristic = characteristic
        }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        if let error = error {
            log.error("Could not publish Loop context service: %{public}@", String(describing: error))
        }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didSubscribeTo characteristic: CBCharacteristic) {
        guard characteristic.uuid == Self.contextUUID else {
            return
        }
        log.default("Watch subscribed to Loop context; sending current state")
        sendContextIfNeeded()
    }

    func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) {
        drainChunks()
    }
}
