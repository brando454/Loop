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
/// Wear OS watch. The phone publishes one GATT service; the watch (already
/// bonded to the iPhone for ANCS) subscribes to the context characteristic and
/// receives a binary-plist envelope, chunked to fit notification payloads:
///
///     byte 0: flags (bit 0 = first chunk, bit 1 = last chunk)
///     byte 1: sequence number within the message
///     rest:   payload
///
/// The envelope is `["v": 1, "ctx": WatchContext.rawValue, "hg": [[epochSeconds, mgdl]]]`,
/// reusing the exact WatchContext wire format WatchConnectivity transmits, plus
/// recent glucose history for the chart (which the Apple Watch fetches through
/// backfill requests instead).
final class PixelWatchDataManager: NSObject {

    /// Must match the LOOP_* UUIDs on the watch side (watch-iphone-bridge).
    static let serviceUUID = CBUUID(string: "354E12EF-6EA4-4255-B054-9D2A113E2C8D")
    static let contextUUID = CBUUID(string: "219E7627-1F0C-4D0C-951F-FDC44514B868")

    private unowned let deviceManager: DeviceDataManager
    private unowned let watchManager: WatchDataManager

    private let log = DiagnosticLog(category: "PixelWatchDataManager")
    private let queue = DispatchQueue(label: "com.loopkit.Loop.PixelWatchDataManager.queue")

    private var peripheralManager: CBPeripheralManager!
    private var contextCharacteristic: CBMutableCharacteristic?

    /// Chunks of the in-flight message; replaced whenever a newer context arrives.
    private var pendingChunks: [Data] = []

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
            self.makeEnvelope(for: context) { envelope in
                self.queue.async {
                    self.enqueue(envelope)
                }
            }
        }
    }

    private func makeEnvelope(for context: WatchContext, completion: @escaping (Data?) -> Void) {
        let start = Date(timeIntervalSinceNow: -historicalGlucoseInterval)
        deviceManager.glucoseStore.getGlucoseSamples(start: start, end: nil) { result in
            var history: [[Double]] = []
            if case .success(let samples) = result {
                history = samples.map {
                    [$0.startDate.timeIntervalSince1970, $0.quantity.doubleValue(for: .milligramsPerDeciliter)]
                }
            }

            var rawContext = context.rawValue
            // Pump/CGM manager internals aren't needed for display
            rawContext["cgmManagerState"] = nil

            let envelope: [String: Any] = [
                "v": 1,
                "ctx": rawContext,
                "hg": history
            ]

            do {
                completion(try PropertyListSerialization.data(fromPropertyList: envelope, format: .binary, options: 0))
            } catch {
                self.log.error("Could not serialize context envelope: %{public}@", String(describing: error))
                completion(nil)
            }
        }
    }

    /// Runs on `queue`.
    private func enqueue(_ envelope: Data?) {
        guard let envelope = envelope,
              let characteristic = contextCharacteristic,
              let centrals = characteristic.subscribedCentrals,
              let maximumUpdateValueLength = centrals.map({ $0.maximumUpdateValueLength }).min()
        else {
            return
        }

        let headerSize = 2
        let chunkSize = max(20 - headerSize, maximumUpdateValueLength - headerSize)

        var chunks: [Data] = []
        var offset = 0
        var sequence: UInt8 = 0
        while offset < envelope.count {
            let end = min(offset + chunkSize, envelope.count)
            var flags: UInt8 = 0
            if offset == 0 {
                flags |= 0x01
            }
            if end == envelope.count {
                flags |= 0x02
            }
            var chunk = Data([flags, sequence])
            chunk.append(envelope.subdata(in: offset..<end))
            chunks.append(chunk)
            sequence = sequence &+ 1
            offset = end
        }

        // The watch resets its reassembly buffer on every first-flagged chunk,
        // so replacing an unfinished message with a newer one is safe.
        pendingChunks = chunks
        drainChunks()
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
                    properties: [.notifyEncryptionRequired],
                    value: nil,
                    permissions: []
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
