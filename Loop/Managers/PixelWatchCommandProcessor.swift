//
//  PixelWatchCommandProcessor.swift
//  Loop
//
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//

import Foundation
import LoopKit

/// Validates a Pixel Watch override command and decides whether settings may change.
///
/// The watch never supplies a glucose target. Pre-Meal uses the stored pre-meal range.
/// Workout uses a named preset id. Carb and bolus commands are rejected.
/// Wire format: `docs/pixel-watch-protocol.md`.
struct PixelWatchCommandProcessor {
    static let schemaVersion = 1
    static let commandMaxAge: TimeInterval = 2 * 60
    /// Watches run a little fast. A timestamp this far ahead of the phone is still accepted.
    static let futureSkew: TimeInterval = 5
    static let dedupeInterval: TimeInterval = TimeInterval(hours: 24)
    static let defaultPreMealDuration: TimeInterval = TimeInterval(hours: 1)
    static let maxCommandBytes = 2048

    static let userDefaultsTestModeKey = "com.loopkit.Loop.PixelWatchCommandTestMode"
    static let userDefaultsReceiptsKey = "com.loopkit.Loop.PixelWatchCommandReceipts"

    static let unsupportedCommands: Set<String> = [
        "carbs",
        "carbs.entry",
        "carbs.start",
        "bolus",
        "bolus.enact",
        "bolus.start",
        "recommend"
    ]

    private static let customTargetKeys: Set<String> = [
        "targetLowerMgdl",
        "targetUpperMgdl",
        "targetRange",
        "target",
        "insulinNeedsScaleFactor",
        "symbol"
    ]

    var receipts: [PixelWatchCommandReceipt]
    var testMode: Bool

    mutating func handle(_ object: Any?, settings: LoopSettings, now: Date = Date()) -> PixelWatchCommandOutcome {
        pruneReceipts(now: now)

        guard let plist = object as? [String: Any] else {
            return finish(ack: PixelWatchCommandAck(requestId: nil, status: .rejected, reason: PixelWatchCommandReason.malformed.rawValue), effect: nil, commandName: nil, presetId: nil, duplicate: false)
        }

        let requestId = Self.parseUUID(plist["requestId"])
        if let requestId, let prior = receipts.last(where: { $0.requestId == requestId }) {
            return PixelWatchCommandOutcome(
                ack: prior.ack,
                effect: nil,
                commandName: prior.commandName,
                presetId: nil,
                duplicate: true,
                testMode: testMode
            )
        }

        if plist["v"] == nil {
            return reject(requestId, .malformed, commandName: plist["cmd"] as? String, presetId: nil, now: now)
        }
        if Self.intValue(plist["v"]) != Self.schemaVersion {
            return reject(requestId, .unsupportedVersion, commandName: plist["cmd"] as? String, presetId: nil, now: now)
        }

        guard let commandName = plist["cmd"] as? String, !commandName.isEmpty else {
            return reject(requestId, .malformed, commandName: nil, presetId: nil, now: now)
        }
        if Self.unsupportedCommands.contains(commandName) {
            return reject(requestId, .unsupported, commandName: commandName, presetId: nil, now: now)
        }
        guard let command = PixelWatchCommandName(rawValue: commandName) else {
            return reject(requestId, .unknownCommand, commandName: commandName, presetId: nil, now: now)
        }
        guard let requestId else {
            return reject(nil, .malformed, commandName: commandName, presetId: nil, now: now)
        }
        guard let timestamp = plist["timestamp"] as? Date else {
            return reject(requestId, .malformed, commandName: commandName, presetId: nil, now: now)
        }
        if timestamp > now.addingTimeInterval(Self.futureSkew) {
            return reject(requestId, .future, commandName: commandName, presetId: nil, now: now)
        }
        if now.timeIntervalSince(timestamp) > Self.commandMaxAge {
            return reject(requestId, .stale, commandName: commandName, presetId: nil, now: now)
        }
        if !Self.customTargetKeys.isDisjoint(with: plist.keys) {
            return reject(requestId, .customTarget, commandName: commandName, presetId: Self.uuidString(plist["presetId"]), now: now)
        }

        switch command {
        case .preMealStart:
            return startPreMeal(requestId: requestId, plist: plist, settings: settings, now: now)
        case .preMealStop:
            return accept(requestId, commandName: command.rawValue, presetId: nil, effect: .preMealStop, now: now)
        case .presetStart:
            return startPreset(requestId: requestId, plist: plist, settings: settings, now: now)
        case .presetStop:
            return accept(requestId, commandName: command.rawValue, presetId: nil, effect: .presetStop, now: now)
        }
    }

    private mutating func startPreMeal(requestId: UUID, plist: [String: Any], settings: LoopSettings, now: Date) -> PixelWatchCommandOutcome {
        let duration: TimeInterval
        if plist["durationSeconds"] == nil {
            duration = Self.defaultPreMealDuration
        } else if let parsed = Self.finiteDuration(plist["durationSeconds"]) {
            duration = parsed
        } else if let seconds = Self.doubleValue(plist["durationSeconds"]), seconds > LoopConstants.maxOverrideDurationTime {
            return reject(requestId, .durationTooLong, commandName: PixelWatchCommandName.preMealStart.rawValue, presetId: nil, now: now)
        } else {
            return reject(requestId, .durationInvalid, commandName: PixelWatchCommandName.preMealStart.rawValue, presetId: nil, now: now)
        }
        if duration > LoopConstants.maxOverrideDurationTime {
            return reject(requestId, .durationTooLong, commandName: PixelWatchCommandName.preMealStart.rawValue, presetId: nil, now: now)
        }
        guard settings.preMealTargetRange != nil else {
            return reject(requestId, .preMealUnavailable, commandName: PixelWatchCommandName.preMealStart.rawValue, presetId: nil, now: now)
        }
        return accept(requestId, commandName: PixelWatchCommandName.preMealStart.rawValue, presetId: nil, effect: .preMealStart(duration), now: now)
    }

    private mutating func startPreset(requestId: UUID, plist: [String: Any], settings: LoopSettings, now: Date) -> PixelWatchCommandOutcome {
        let commandName = PixelWatchCommandName.presetStart.rawValue
        guard plist["presetId"] != nil else {
            return reject(requestId, .missingPreset, commandName: commandName, presetId: nil, now: now)
        }
        guard let presetId = Self.parseUUID(plist["presetId"]) else {
            return reject(requestId, .malformed, commandName: commandName, presetId: Self.uuidString(plist["presetId"]), now: now)
        }
        guard let preset = settings.overridePresets.first(where: { $0.id == presetId }) else {
            return reject(requestId, .unknownPreset, commandName: commandName, presetId: presetId.uuidString, now: now)
        }

        let duration: TemporaryScheduleOverride.Duration
        if plist["durationSeconds"] == nil {
            switch preset.duration {
            case .indefinite:
                duration = .indefinite
            case .finite(let seconds) where seconds > 0 && seconds <= LoopConstants.maxOverrideDurationTime:
                duration = .finite(seconds)
            case .finite(let seconds) where seconds > LoopConstants.maxOverrideDurationTime:
                return reject(requestId, .durationTooLong, commandName: commandName, presetId: presetId.uuidString, now: now)
            case .finite:
                return reject(requestId, .durationInvalid, commandName: commandName, presetId: presetId.uuidString, now: now)
            }
        } else if let seconds = Self.finiteDuration(plist["durationSeconds"]) {
            duration = .finite(seconds)
        } else if let seconds = Self.doubleValue(plist["durationSeconds"]), seconds > LoopConstants.maxOverrideDurationTime {
            return reject(requestId, .durationTooLong, commandName: commandName, presetId: presetId.uuidString, now: now)
        } else {
            return reject(requestId, .durationInvalid, commandName: commandName, presetId: presetId.uuidString, now: now)
        }

        return accept(requestId, commandName: commandName, presetId: presetId.uuidString, effect: .presetStart(id: presetId, duration: duration), now: now)
    }

    private mutating func accept(_ requestId: UUID, commandName: String, presetId: String?, effect: PixelWatchOverrideEffect, now: Date) -> PixelWatchCommandOutcome {
        if testMode {
            return finish(
                ack: PixelWatchCommandAck(requestId: requestId, status: .ok, reason: PixelWatchCommandReason.testMode.rawValue),
                effect: nil,
                commandName: commandName,
                presetId: presetId,
                duplicate: false,
                store: true,
                now: now
            )
        }
        return finish(
            ack: PixelWatchCommandAck(requestId: requestId, status: .ok, reason: nil),
            effect: effect,
            commandName: commandName,
            presetId: presetId,
            duplicate: false,
            store: true,
            now: now
        )
    }

    private mutating func reject(_ requestId: UUID?, _ reason: PixelWatchCommandReason, commandName: String?, presetId: String?, now: Date) -> PixelWatchCommandOutcome {
        return finish(
            ack: PixelWatchCommandAck(requestId: requestId, status: .rejected, reason: reason.rawValue),
            effect: nil,
            commandName: commandName,
            presetId: presetId,
            duplicate: false,
            store: requestId != nil,
            now: now
        )
    }

    private mutating func finish(
        ack: PixelWatchCommandAck,
        effect: PixelWatchOverrideEffect?,
        commandName: String?,
        presetId: String?,
        duplicate: Bool,
        store: Bool = false,
        now: Date = Date()
    ) -> PixelWatchCommandOutcome {
        if store, let requestId = ack.requestId {
            receipts.append(PixelWatchCommandReceipt(
                requestId: requestId,
                status: ack.status,
                reason: ack.reason,
                commandName: commandName,
                receivedAt: now
            ))
        }
        return PixelWatchCommandOutcome(
            ack: ack,
            effect: effect,
            commandName: commandName,
            presetId: presetId,
            duplicate: duplicate,
            testMode: testMode
        )
    }

    /// The preset or pre-meal target disappeared after validation. A replay of this request id returns this error and does not apply again.
    mutating func markApplyFailed(requestId: UUID) -> PixelWatchCommandAck {
        let reason = PixelWatchCommandReason.internal.rawValue
        if let index = receipts.lastIndex(where: { $0.requestId == requestId }) {
            receipts[index].status = .error
            receipts[index].reason = reason
        }
        return PixelWatchCommandAck(requestId: requestId, status: .error, reason: reason)
    }

    private mutating func pruneReceipts(now: Date) {
        receipts.removeAll { now.timeIntervalSince($0.receivedAt) > Self.dedupeInterval }
    }

    static func receipts(from defaults: UserDefaults) throws -> [PixelWatchCommandReceipt] {
        guard let data = defaults.data(forKey: userDefaultsReceiptsKey) else {
            return []
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try decoder.decode([PixelWatchCommandReceipt].self, from: data)
    }

    static func store(_ receipts: [PixelWatchCommandReceipt], in defaults: UserDefaults) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let data = try encoder.encode(receipts)
        defaults.set(data, forKey: userDefaultsReceiptsKey)
    }

    /// A positive finite duration no longer than `LoopConstants.maxOverrideDurationTime`.
    private static func finiteDuration(_ value: Any?) -> TimeInterval? {
        guard let seconds = doubleValue(value), seconds > 0, seconds <= LoopConstants.maxOverrideDurationTime, seconds.isFinite else {
            return nil
        }
        return seconds
    }

    private static func doubleValue(_ value: Any?) -> Double? {
        if value is Bool {
            return nil
        }
        if let value = value as? Double {
            return value
        }
        if let value = value as? Int {
            return Double(value)
        }
        if let number = value as? NSNumber {
            return number.doubleValue
        }
        return nil
    }

    private static func intValue(_ value: Any?) -> Int? {
        if value is Bool {
            return nil
        }
        if let value = value as? Int {
            return value
        }
        if let number = value as? NSNumber {
            return number.intValue
        }
        return nil
    }

    private static func parseUUID(_ value: Any?) -> UUID? {
        guard let string = value as? String else {
            return nil
        }
        return UUID(uuidString: string.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func uuidString(_ value: Any?) -> String? {
        value as? String
    }
}

enum PixelWatchCommandName: String, Equatable {
    case preMealStart = "preMeal.start"
    case preMealStop = "preMeal.stop"
    case presetStart = "preset.start"
    case presetStop = "preset.stop"
}

enum PixelWatchCommandReason: String, Equatable {
    case testMode
    case stale
    case future
    case malformed
    case unknownCommand
    case unsupported
    case unsupportedVersion
    case missingPreset
    case unknownPreset
    case preMealUnavailable
    case durationInvalid
    case durationTooLong
    case customTarget
    case `internal`
}

enum PixelWatchOverrideEffect: Equatable {
    case preMealStart(TimeInterval)
    case preMealStop
    case presetStart(id: UUID, duration: TemporaryScheduleOverride.Duration)
    case presetStop
}

struct PixelWatchCommandAck: Equatable {
    enum Status: String, Equatable, Codable {
        case ok
        case rejected
        case error
    }

    var requestId: UUID?
    var status: Status
    var reason: String?

    var envelope: [String: Any] {
        var ack: [String: Any] = [
            "status": status.rawValue
        ]
        if let requestId {
            ack["requestId"] = requestId.uuidString
        }
        if let reason {
            ack["reason"] = reason
        }
        return [
            "v": PixelWatchActionsSnapshot.envelopeVersion,
            "ack": ack
        ]
    }
}

struct PixelWatchCommandOutcome: Equatable {
    var ack: PixelWatchCommandAck
    var effect: PixelWatchOverrideEffect?
    var commandName: String?
    var presetId: String?
    var duplicate: Bool
    var testMode: Bool
}

struct PixelWatchCommandReceipt: Equatable, Codable {
    var requestId: UUID
    var status: PixelWatchCommandAck.Status
    var reason: String?
    var commandName: String?
    var receivedAt: Date

    var ack: PixelWatchCommandAck {
        PixelWatchCommandAck(requestId: requestId, status: status, reason: reason)
    }
}

enum PixelWatchOverrideApplicator {
    /// Applies an already-validated effect with the phone UI's settings APIs.
    /// Returns false when the preset or pre-meal target disappeared before the write landed.
    static func apply(_ effect: PixelWatchOverrideEffect, to settings: inout LoopSettings, at date: Date) -> Bool {
        switch effect {
        case .preMealStart(let duration):
            guard settings.preMealTargetRange != nil,
                  duration > 0,
                  duration <= LoopConstants.maxOverrideDurationTime
            else {
                return false
            }
            settings.enablePreMealOverride(at: date, for: duration)
            return settings.preMealOverride != nil
        case .preMealStop:
            settings.clearOverride(matching: .preMeal)
            return true
        case .presetStart(let id, let duration):
            guard duration.timeInterval > 0 else {
                return false
            }
            if case .finite(let seconds) = duration, seconds > LoopConstants.maxOverrideDurationTime {
                return false
            }
            guard let preset = settings.overridePresets.first(where: { $0.id == id }) else {
                return false
            }
            // createOverride copies the stored duration into an override, which traps when that duration is not positive.
            // A duration the watch sent is applied after the phone UI's createOverride call when the stored one is usable.
            var override: TemporaryScheduleOverride
            if preset.duration.timeInterval > 0 {
                override = preset.createOverride(enactTrigger: .local, beginningAt: date)
                override.duration = duration
            } else {
                override = TemporaryScheduleOverride(
                    context: .preset(preset),
                    settings: preset.settings,
                    startDate: date,
                    duration: duration,
                    enactTrigger: .local,
                    syncIdentifier: UUID()
                )
            }
            settings.scheduleOverride = override
            return true
        case .presetStop:
            settings.clearOverride()
            return true
        }
    }
}

enum PixelWatchWriteAssembler {
    enum Failure: Equatable {
        case empty
        case gap
        case tooLarge
    }

    static func assemble(_ parts: [(offset: Int, value: Data)]) -> Result<Data, Failure> {
        guard !parts.isEmpty else {
            return .failure(.empty)
        }
        let sorted = parts.sorted { lhs, rhs in
            if lhs.offset == rhs.offset {
                return lhs.value.count < rhs.value.count
            }
            return lhs.offset < rhs.offset
        }
        guard sorted[0].offset == 0 else {
            return .failure(.gap)
        }
        var data = Data()
        var cursor = 0
        for part in sorted {
            if part.value.isEmpty || part.offset != cursor {
                return .failure(part.value.isEmpty ? .empty : .gap)
            }
            if data.count + part.value.count > PixelWatchCommandProcessor.maxCommandBytes {
                return .failure(.tooLarge)
            }
            data.append(part.value)
            cursor += part.value.count
        }
        return .success(data)
    }
}
