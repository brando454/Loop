//
//  PixelWatchActionsSnapshot.swift
//  Loop
//
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//

import Foundation
import HealthKit
import LoopCore
import LoopKit

/// Read-only actions metadata added to the Pixel Watch BLE envelope.
///
/// The envelope version stays `1` so a watch that already reads `v`, `ctx`, and `hg`
/// keeps working. New data lives under `act` and is versioned by `act.v`.
/// This value describes state only. Override commands are handled separately
/// and cannot set a custom target from the watch.
/// Wire format: `docs/pixel-watch-protocol.md`.
struct PixelWatchActionsSnapshot {
    static let envelopeVersion = 1
    static let actionsSchemaVersion = 1

    /// First N presets in Loop's list order. The rest are not sent; `presetsTruncated` is true.
    static let maxPresets = 16

    let fullEnvelope: [String: Any]
    let presetsOmittedEnvelope: [String: Any]
    let legacyEnvelope: [String: Any]
    let includedPresetCount: Int

    static func make(
        context: WatchContext,
        glucoseHistory: [[Double]],
        settings: LoopSettings,
        pumpDataDate: Date,
        defaultCarbAbsorption: TimeInterval,
        now: Date = Date()
    ) -> PixelWatchActionsSnapshot {
        let cappedPresets = Array(settings.overridePresets.prefix(maxPresets))
        let truncatedByCount = settings.overridePresets.count > maxPresets
        let contextRaw = contextDictionary(context)

        let fullActions = actionsDictionary(
            context: context,
            settings: settings,
            pumpDataDate: pumpDataDate,
            defaultCarbAbsorption: defaultCarbAbsorption,
            now: now,
            presets: cappedPresets,
            presetsTruncated: truncatedByCount,
            includePresets: true
        )
        let presetsOmittedActions = actionsDictionary(
            context: context,
            settings: settings,
            pumpDataDate: pumpDataDate,
            defaultCarbAbsorption: defaultCarbAbsorption,
            now: now,
            presets: [],
            presetsTruncated: true,
            includePresets: false
        )

        return PixelWatchActionsSnapshot(
            fullEnvelope: envelope(versionedContext: contextRaw, glucoseHistory: glucoseHistory, actions: fullActions),
            presetsOmittedEnvelope: envelope(versionedContext: contextRaw, glucoseHistory: glucoseHistory, actions: presetsOmittedActions),
            legacyEnvelope: envelope(versionedContext: contextRaw, glucoseHistory: glucoseHistory, actions: nil),
            includedPresetCount: cappedPresets.count
        )
    }

    /// Binary-plist bytes framed for the notify characteristic.
    ///
    /// Prefers the full snapshot. If that would use more than `maxChunks` notifications,
    /// drops the preset list, then drops `act` entirely. The legacy envelope is the
    /// pre-actions payload and is what gets sent when nothing richer fits. Sequence
    /// numbers are a single byte, so a message past `maxChunks` cannot be reassembled.
    func framedPayload(
        maximumUpdateValueLength: Int,
        maxChunks: Int = PixelWatchNotificationFraming.maxChunks
    ) -> PixelWatchFramedPayload? {
        var candidates: [(PixelWatchFramedPayload.Kind, [String: Any])] = [
            (.full, fullEnvelope)
        ]
        if includedPresetCount > 0 {
            candidates.append((.presetsOmitted, presetsOmittedEnvelope))
        }
        candidates.append((.actionsOmitted, legacyEnvelope))

        var smallest: PixelWatchFramedPayload?
        for (kind, plist) in candidates {
            guard let data = try? PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0) else {
                continue
            }
            let chunks = PixelWatchNotificationFraming.chunks(of: data, maximumUpdateValueLength: maximumUpdateValueLength)
            let framed = PixelWatchFramedPayload(kind: kind, chunks: chunks)
            smallest = framed
            if chunks.count <= maxChunks {
                return framed
            }
        }
        return smallest
    }

    private static func envelope(
        versionedContext: [String: Any],
        glucoseHistory: [[Double]],
        actions: [String: Any]?
    ) -> [String: Any] {
        var raw: [String: Any] = [
            "v": envelopeVersion,
            "ctx": versionedContext,
            "hg": glucoseHistory
        ]
        if let actions = actions {
            raw["act"] = actions
        }
        return raw
    }

    private static func contextDictionary(_ context: WatchContext) -> [String: Any] {
        var raw = context.rawValue
        // Pump and CGM manager internals are not display data.
        raw["cgmManagerState"] = nil
        return raw
    }

    private static func actionsDictionary(
        context: WatchContext,
        settings: LoopSettings,
        pumpDataDate: Date,
        defaultCarbAbsorption: TimeInterval,
        now: Date,
        presets: [TemporaryScheduleOverridePreset],
        presetsTruncated: Bool,
        includePresets: Bool
    ) -> [String: Any] {
        var raw: [String: Any] = [
            "v": actionsSchemaVersion,
            "cap": capabilityDictionary(),
            "presetsTruncated": presetsTruncated,
            "preMeal": preMealDictionary(settings: settings, now: now),
            "limits": limitsDictionary(settings: settings, defaultCarbAbsorption: defaultCarbAbsorption),
            "bolus": bolusDictionary(context: context, pumpDataDate: pumpDataDate)
        ]
        if includePresets {
            raw["presets"] = presets.map(presetDictionary)
        }
        if let scheduleOverride = settings.scheduleOverride,
           let described = runningOverrideDictionary(scheduleOverride, now: now) {
            raw["override"] = described
        }
        return raw
    }

    /// Commands this phone will accept. Carb and bolus writes are still refused.
    private static func capabilityDictionary() -> [String: Bool] {
        return [
            "preMeal": true,
            "workout": true,
            "carbs": false,
            "bolus": false
        ]
    }

    private static func presetDictionary(_ preset: TemporaryScheduleOverridePreset) -> [String: Any] {
        var raw: [String: Any] = [
            "id": preset.id.uuidString,
            "name": preset.name,
            "symbol": preset.symbol
        ]
        switch preset.duration {
        case .indefinite:
            raw["indefinite"] = true
        case .finite(let seconds):
            raw["indefinite"] = false
            raw["durationSeconds"] = seconds
        }
        appendOverrideSettings(preset.settings, to: &raw)
        return raw
    }

    private static func preMealDictionary(settings: LoopSettings, now: Date) -> [String: Any] {
        var raw: [String: Any] = [
            "available": settings.preMealTargetRange != nil,
            "active": false
        ]
        appendGlucoseTarget(settings.preMealTargetRange, to: &raw)
        if let preMealOverride = settings.preMealOverride,
           let described = runningOverrideDictionary(preMealOverride, now: now) {
            raw["active"] = described["active"] as? Bool ?? false
            if let start = described["start"] {
                raw["start"] = start
            }
            raw["indefinite"] = described["indefinite"] as? Bool ?? false
            if let end = described["end"] {
                raw["end"] = end
            }
        }
        return raw
    }

    /// A schedule override that has not finished. Deleted and finished overrides are omitted.
    private static func runningOverrideDictionary(_ running: TemporaryScheduleOverride, now: Date) -> [String: Any]? {
        if case .deleted = running.actualEnd {
            return nil
        }

        let active: Bool
        let indefinite: Bool
        let end: Date?
        if running.duration.isInfinite, case .natural = running.actualEnd {
            indefinite = true
            active = now >= running.startDate
            end = nil
        } else if running.hasFinished(relativeTo: now) {
            return nil
        } else {
            indefinite = false
            active = running.isActive(at: now)
            end = running.actualEndDate
        }

        var raw: [String: Any] = [
            "active": active,
            "indefinite": indefinite,
            "start": running.startDate
        ]
        if let end = end {
            raw["end"] = end
        }

        switch running.context {
        case .preset(let preset):
            raw["kind"] = "preset"
            raw["presetId"] = preset.id.uuidString
            raw["name"] = preset.name
            raw["symbol"] = preset.symbol
        case .custom:
            raw["kind"] = "custom"
        case .legacyWorkout:
            raw["kind"] = "legacyWorkout"
        case .preMeal:
            raw["kind"] = "preMeal"
        }
        appendOverrideSettings(running.settings, to: &raw)
        return raw
    }

    private static func limitsDictionary(settings: LoopSettings, defaultCarbAbsorption: TimeInterval) -> [String: Any] {
        var raw: [String: Any] = [
            "maxCarbGrams": LoopConstants.maxCarbEntryQuantity.doubleValue(for: .gram()),
            "minCarbAbsorptionSeconds": LoopConstants.minCarbAbsorptionTime,
            "maxCarbAbsorptionSeconds": LoopConstants.maxCarbAbsorptionTime,
            "defaultCarbAbsorptionSeconds": defaultCarbAbsorption,
            "carbEntryPastSeconds": LoopConstants.maxCarbEntryPastTime,
            "carbEntryFutureSeconds": LoopConstants.maxCarbEntryFutureTime,
            "inputDataRecencySeconds": LoopCoreConstants.inputDataRecencyInterval,
            "maxOverrideDurationSeconds": LoopConstants.maxOverrideDurationTime
        ]
        if let maximumBolus = settings.maximumBolus {
            raw["maximumBolus"] = maximumBolus
        }
        return raw
    }

    private static func bolusDictionary(context: WatchContext, pumpDataDate: Date) -> [String: Any] {
        var raw: [String: Any] = [
            "snapshotDate": context.creationDate,
            "pumpDataDate": pumpDataDate
        ]
        if let recommended = context.recommendedBolusDose {
            raw["recommendedUnits"] = recommended
        }
        if let glucoseDate = context.glucoseDate {
            raw["glucoseDate"] = glucoseDate
        }
        return raw
    }

    private static func appendOverrideSettings(_ settings: TemporaryScheduleOverrideSettings, to raw: inout [String: Any]) {
        appendGlucoseTarget(settings.targetRange, to: &raw)
        if let scale = settings.insulinNeedsScaleFactor {
            raw["insulinNeedsScaleFactor"] = scale
        }
    }

    private static func appendGlucoseTarget(_ range: ClosedRange<HKQuantity>?, to raw: inout [String: Any]) {
        guard let range = range else {
            return
        }
        let unit = HKUnit.milligramsPerDeciliter
        raw["targetLowerMgdl"] = range.lowerBound.doubleValue(for: unit)
        raw["targetUpperMgdl"] = range.upperBound.doubleValue(for: unit)
    }
}

struct PixelWatchFramedPayload {
    enum Kind: Equatable {
        /// `act` includes the preset list (capped).
        case full
        /// `act` is present and `presetsTruncated` is true, but `presets` was left out.
        case presetsOmitted
        /// Envelope is `v`, `ctx`, and `hg` only.
        case actionsOmitted
    }

    var kind: Kind
    var chunks: [Data]
}

enum PixelWatchNotificationFraming {
    static let headerSize = 2
    /// Sequence is one byte. Chunk 0...255 is the whole message space.
    static let maxChunks = 256

    /// Same framing `PixelWatchDataManager` has always used:
    /// byte 0 flags (bit 0 first, bit 1 last), byte 1 sequence, then payload.
    static func chunks(of envelope: Data, maximumUpdateValueLength: Int) -> [Data] {
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
        return chunks
    }
}
