//
//  PixelWatchCommandProcessorTests.swift
//  LoopTests
//
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//

import CoreBluetooth
import HealthKit
import LoopCore
import LoopKit
import XCTest
@testable import Loop

class PixelWatchCommandProcessorTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private let presetID = UUID(uuidString: "2F1C0A7E-6B4D-4E2A-9C11-8A0B1C2D3E4F")!

    func testPreMealStartUsesStoredTargetAndOneHourWhenDurationIsOmitted() {
        var processor = PixelWatchCommandProcessor(receipts: [], testMode: false)
        let outcome = processor.handle(command("preMeal.start"), settings: configuredSettings(), now: now)

        XCTAssertEqual(PixelWatchCommandProcessor.defaultPreMealDuration, 60 * 60)
        XCTAssertEqual(outcome.ack.status, .ok)
        XCTAssertNil(outcome.ack.reason)
        XCTAssertFalse(outcome.duplicate)
        XCTAssertEqual(outcome.effect, .preMealStart(60 * 60))
        XCTAssertEqual(processor.receipts.count, 1)
    }

    func testPreMealStartHonorsDurationAndRejectsZeroAndOverTheCap() {
        var processor = PixelWatchCommandProcessor(receipts: [], testMode: false)
        let accepted = processor.handle(
            command("preMeal.start", durationSeconds: LoopConstants.maxOverrideDurationTime),
            settings: configuredSettings(),
            now: now
        )
        XCTAssertEqual(accepted.effect, .preMealStart(LoopConstants.maxOverrideDurationTime))

        let zero = processor.handle(command("preMeal.start", durationSeconds: 0), settings: configuredSettings(), now: now)
        XCTAssertEqual(zero.ack.status, .rejected)
        XCTAssertEqual(zero.ack.reason, PixelWatchCommandReason.durationInvalid.rawValue)
        XCTAssertNil(zero.effect)

        let negative = processor.handle(command("preMeal.start", durationSeconds: -5), settings: configuredSettings(), now: now)
        XCTAssertEqual(negative.ack.reason, PixelWatchCommandReason.durationInvalid.rawValue)
        XCTAssertNil(negative.effect)

        let tooLong = processor.handle(
            command("preMeal.start", durationSeconds: LoopConstants.maxOverrideDurationTime + 1),
            settings: configuredSettings(),
            now: now
        )
        XCTAssertEqual(tooLong.ack.reason, PixelWatchCommandReason.durationTooLong.rawValue)
        XCTAssertNil(tooLong.effect)
    }

    func testPreMealStartRequiresAStoredTargetAndStopDoesNotNeedOne() {
        var processor = PixelWatchCommandProcessor(receipts: [], testMode: false)
        let missing = processor.handle(command("preMeal.start"), settings: LoopSettings(), now: now)
        XCTAssertEqual(missing.ack.status, .rejected)
        XCTAssertEqual(missing.ack.reason, PixelWatchCommandReason.preMealUnavailable.rawValue)
        XCTAssertNil(missing.effect)

        let stop = processor.handle(command("preMeal.stop"), settings: LoopSettings(), now: now)
        XCTAssertEqual(stop.ack.status, .ok)
        XCTAssertEqual(stop.effect, .preMealStop)
    }

    func testStopIgnoresDurationAndPresetId() {
        var processor = PixelWatchCommandProcessor(receipts: [], testMode: false)
        let stop = processor.handle(
            command("preset.stop", presetId: presetID, durationSeconds: 0),
            settings: configuredSettings(),
            now: now
        )
        XCTAssertEqual(stop.ack.status, .ok)
        XCTAssertNil(stop.ack.reason)
        XCTAssertEqual(stop.effect, .presetStop)
    }

    func testPresetStartUsesStoredDurationAndRejectsAnUnknownId() {
        var processor = PixelWatchCommandProcessor(receipts: [], testMode: false)
        let settings = configuredSettings(duration: .finite(45 * 60))
        let started = processor.handle(command("preset.start", presetId: presetID), settings: settings, now: now)
        XCTAssertEqual(started.ack.status, .ok)
        XCTAssertEqual(started.effect, .presetStart(id: presetID, duration: .finite(45 * 60)))

        let indefinite = processor.handle(
            command("preset.start", presetId: presetID),
            settings: configuredSettings(duration: .indefinite),
            now: now
        )
        XCTAssertEqual(indefinite.effect, .presetStart(id: presetID, duration: .indefinite))

        let unknown = processor.handle(command("preset.start", presetId: UUID()), settings: settings, now: now)
        XCTAssertEqual(unknown.ack.status, .rejected)
        XCTAssertEqual(unknown.ack.reason, PixelWatchCommandReason.unknownPreset.rawValue)
        XCTAssertNil(unknown.effect)

        let missing = processor.handle(command("preset.start"), settings: settings, now: now)
        XCTAssertEqual(missing.ack.reason, PixelWatchCommandReason.missingPreset.rawValue)
        XCTAssertNil(missing.effect)

        let malformed = processor.handle(command("preset.start", presetIdString: "not-a-uuid"), settings: settings, now: now)
        XCTAssertEqual(malformed.ack.reason, PixelWatchCommandReason.malformed.rawValue)
        XCTAssertNil(malformed.effect)
    }

    func testPresetStartAcceptsALowercaseIdAndAnExplicitDuration() {
        var processor = PixelWatchCommandProcessor(receipts: [], testMode: false)
        let started = processor.handle(
            command("preset.start", presetIdString: presetID.uuidString.lowercased(), durationSeconds: 1800),
            settings: configuredSettings(duration: .indefinite),
            now: now
        )
        XCTAssertEqual(started.effect, .presetStart(id: presetID, duration: .finite(1800)))
    }

    func testStoredPresetLongerThanTheCapIsRejected() {
        var processor = PixelWatchCommandProcessor(receipts: [], testMode: false)
        let outcome = processor.handle(
            command("preset.start", presetId: presetID),
            settings: configuredSettings(duration: .finite(LoopConstants.maxOverrideDurationTime + 60)),
            now: now
        )
        XCTAssertEqual(outcome.ack.reason, PixelWatchCommandReason.durationTooLong.rawValue)
        XCTAssertNil(outcome.effect)
    }

    func testCustomTargetKeysAreRejected() {
        var processor = PixelWatchCommandProcessor(receipts: [], testMode: false)
        var plist = command("preMeal.start")
        plist["targetLowerMgdl"] = 90
        let outcome = processor.handle(plist, settings: configuredSettings(), now: now)
        XCTAssertEqual(outcome.ack.status, .rejected)
        XCTAssertEqual(outcome.ack.reason, PixelWatchCommandReason.customTarget.rawValue)
        XCTAssertNil(outcome.effect)
    }

    func testStalenessAndFutureSkew() {
        var processor = PixelWatchCommandProcessor(receipts: [], testMode: false)
        let settings = configuredSettings()

        let fresh = processor.handle(
            command("preMeal.stop", at: now.addingTimeInterval(-PixelWatchCommandProcessor.commandMaxAge)),
            settings: settings,
            now: now
        )
        XCTAssertEqual(fresh.ack.status, .ok)

        let stale = processor.handle(
            command("preMeal.stop", at: now.addingTimeInterval(-PixelWatchCommandProcessor.commandMaxAge - 0.001)),
            settings: settings,
            now: now
        )
        XCTAssertEqual(stale.ack.status, .rejected)
        XCTAssertEqual(stale.ack.reason, PixelWatchCommandReason.stale.rawValue)
        XCTAssertNil(stale.effect)

        let allowedSkew = processor.handle(
            command("preMeal.stop", at: now.addingTimeInterval(PixelWatchCommandProcessor.futureSkew)),
            settings: settings,
            now: now
        )
        XCTAssertEqual(allowedSkew.ack.status, .ok)

        let future = processor.handle(
            command("preMeal.stop", at: now.addingTimeInterval(PixelWatchCommandProcessor.futureSkew + 0.001)),
            settings: settings,
            now: now
        )
        XCTAssertEqual(future.ack.reason, PixelWatchCommandReason.future.rawValue)
        XCTAssertNil(future.effect)
    }

    func testDuplicateRequestIdReturnsTheOriginalAckAndDoesNotRefreshTheWindow() {
        var processor = PixelWatchCommandProcessor(receipts: [], testMode: false)
        let settings = configuredSettings()
        let plist = command("preMeal.start", at: now)
        let first = processor.handle(plist, settings: settings, now: now)
        XCTAssertEqual(first.effect, .preMealStart(PixelWatchCommandProcessor.defaultPreMealDuration))

        let replayNow = now.addingTimeInterval(PixelWatchCommandProcessor.dedupeInterval)
        let replay = processor.handle(plist, settings: settings, now: replayNow)
        XCTAssertTrue(replay.duplicate)
        XCTAssertNil(replay.effect)
        XCTAssertEqual(replay.ack, first.ack)
        XCTAssertEqual(processor.receipts.count, 1)
        XCTAssertEqual(processor.receipts[0].receivedAt, now)

        let expiredAt = replayNow.addingTimeInterval(1)
        var expired = plist
        expired["timestamp"] = expiredAt
        let again = processor.handle(expired, settings: settings, now: expiredAt)
        XCTAssertFalse(again.duplicate)
        XCTAssertEqual(again.effect, .preMealStart(PixelWatchCommandProcessor.defaultPreMealDuration))
        XCTAssertEqual(processor.receipts.count, 1)
        XCTAssertEqual(processor.receipts[0].receivedAt, expiredAt)
    }

    func testRejectedCommandIsDedupedToo() {
        var processor = PixelWatchCommandProcessor(receipts: [], testMode: false)
        let plist = command("preset.start", presetId: UUID(), at: now)
        let first = processor.handle(plist, settings: configuredSettings(), now: now)
        XCTAssertEqual(first.ack.reason, PixelWatchCommandReason.unknownPreset.rawValue)

        let second = processor.handle(plist, settings: configuredSettings(), now: now.addingTimeInterval(30))
        XCTAssertTrue(second.duplicate)
        XCTAssertEqual(second.ack, first.ack)
        XCTAssertNil(second.effect)
        XCTAssertEqual(processor.receipts.count, 1)
    }

    func testMalformedCommandsAndUnsupportedNamesDoNotApply() {
        var processor = PixelWatchCommandProcessor(receipts: [], testMode: false)
        let settings = configuredSettings()

        let notADictionary = processor.handle(["nope"], settings: settings, now: now)
        XCTAssertEqual(notADictionary.ack.status, .rejected)
        XCTAssertEqual(notADictionary.ack.reason, PixelWatchCommandReason.malformed.rawValue)
        XCTAssertNil(notADictionary.ack.requestId)
        XCTAssertTrue(processor.receipts.isEmpty)

        var missingVersion = command("preMeal.stop")
        missingVersion["v"] = nil
        let missingVersionOutcome = processor.handle(missingVersion, settings: settings, now: now)
        XCTAssertEqual(missingVersionOutcome.ack.reason, PixelWatchCommandReason.malformed.rawValue)

        var futureVersion = command("preMeal.stop")
        futureVersion["v"] = 2
        let futureVersionOutcome = processor.handle(futureVersion, settings: settings, now: now)
        XCTAssertEqual(futureVersionOutcome.ack.reason, PixelWatchCommandReason.unsupportedVersion.rawValue)

        var missingCommand = command("preMeal.stop")
        missingCommand["cmd"] = nil
        XCTAssertEqual(processor.handle(missingCommand, settings: settings, now: now).ack.reason, PixelWatchCommandReason.malformed.rawValue)

        let unknown = processor.handle(command("override.start"), settings: settings, now: now)
        XCTAssertEqual(unknown.ack.reason, PixelWatchCommandReason.unknownCommand.rawValue)
        XCTAssertNil(unknown.effect)

        for name in ["carbs", "carbs.entry", "carbs.start", "bolus", "bolus.enact", "bolus.start", "recommend"] {
            let outcome = processor.handle(command(name), settings: settings, now: now)
            XCTAssertEqual(outcome.ack.status, .rejected, name)
            XCTAssertEqual(outcome.ack.reason, PixelWatchCommandReason.unsupported.rawValue, name)
            XCTAssertNil(outcome.effect, name)
        }

        var missingRequest = command("preMeal.stop")
        missingRequest["requestId"] = nil
        let missingRequestOutcome = processor.handle(missingRequest, settings: settings, now: now)
        XCTAssertEqual(missingRequestOutcome.ack.reason, PixelWatchCommandReason.malformed.rawValue)
        XCTAssertNil(missingRequestOutcome.ack.requestId)

        var missingTimestamp = command("preMeal.stop")
        let timestampRequestId = UUID(uuidString: missingTimestamp["requestId"] as! String)
        missingTimestamp["timestamp"] = nil
        let missingTimestampOutcome = processor.handle(missingTimestamp, settings: settings, now: now)
        XCTAssertEqual(missingTimestampOutcome.ack.reason, PixelWatchCommandReason.malformed.rawValue)
        XCTAssertEqual(missingTimestampOutcome.ack.requestId, timestampRequestId)
    }

    func testTestModeValidatesAndDoesNotProduceAnEffect() {
        var processor = PixelWatchCommandProcessor(receipts: [], testMode: true)
        let accepted = processor.handle(command("preset.start", presetId: presetID), settings: configuredSettings(), now: now)
        XCTAssertEqual(accepted.ack.status, .ok)
        XCTAssertEqual(accepted.ack.reason, PixelWatchCommandReason.testMode.rawValue)
        XCTAssertNil(accepted.effect)
        XCTAssertTrue(accepted.testMode)

        let replay = processor.handle(command("preset.start", presetId: presetID, requestId: accepted.ack.requestId), settings: configuredSettings(), now: now)
        XCTAssertTrue(replay.duplicate)
        XCTAssertNil(replay.effect)
        XCTAssertEqual(replay.ack.reason, PixelWatchCommandReason.testMode.rawValue)

        let stale = processor.handle(
            command("preMeal.start", at: now.addingTimeInterval(-PixelWatchCommandProcessor.commandMaxAge - 1)),
            settings: configuredSettings(),
            now: now
        )
        XCTAssertEqual(stale.ack.status, .rejected)
        XCTAssertEqual(stale.ack.reason, PixelWatchCommandReason.stale.rawValue)
        XCTAssertNil(stale.effect)
    }

    func testApplyFailureIsWhatAReplayReturns() throws {
        var processor = PixelWatchCommandProcessor(receipts: [], testMode: false)
        let first = processor.handle(command("preMeal.stop"), settings: configuredSettings(), now: now)
        let requestId = try XCTUnwrap(first.ack.requestId)
        let failed = processor.markApplyFailed(requestId: requestId)
        XCTAssertEqual(failed.status, .error)
        XCTAssertEqual(failed.reason, PixelWatchCommandReason.internal.rawValue)

        let replay = processor.handle(command("preMeal.stop", requestId: requestId), settings: configuredSettings(), now: now)
        XCTAssertTrue(replay.duplicate)
        XCTAssertNil(replay.effect)
        XCTAssertEqual(replay.ack.status, .error)
        XCTAssertEqual(replay.ack.reason, PixelWatchCommandReason.internal.rawValue)
    }

    func testBinaryPlistRoundTripPreservesThePresetCommand() throws {
        let requestId = UUID()
        let plist: [String: Any] = [
            "v": 1,
            "cmd": "preset.start",
            "requestId": requestId.uuidString,
            "timestamp": now,
            "presetId": presetID.uuidString,
            "durationSeconds": 1800
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
        let decoded = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)

        var processor = PixelWatchCommandProcessor(receipts: [], testMode: false)
        let outcome = processor.handle(decoded, settings: configuredSettings(), now: now)
        XCTAssertEqual(outcome.ack.status, .ok)
        XCTAssertEqual(outcome.ack.requestId, requestId)
        XCTAssertEqual(outcome.effect, .presetStart(id: presetID, duration: .finite(1800)))
    }

    func testAckEnvelopeAndFraming() throws {
        let requestId = UUID()
        let ack = PixelWatchCommandAck(requestId: requestId, status: .rejected, reason: PixelWatchCommandReason.stale.rawValue)
        let envelope = ack.envelope
        XCTAssertEqual(Set(envelope.keys), Set(["v", "ack"]))
        XCTAssertEqual(envelope["v"] as? Int, PixelWatchActionsSnapshot.envelopeVersion)
        let body = try XCTUnwrap(envelope["ack"] as? [String: Any])
        XCTAssertEqual(body["requestId"] as? String, requestId.uuidString)
        XCTAssertEqual(body["status"] as? String, "rejected")
        XCTAssertEqual(body["reason"] as? String, "stale")

        let accepted = PixelWatchCommandAck(requestId: requestId, status: .ok, reason: nil)
        let acceptedBody = try XCTUnwrap(accepted.envelope["ack"] as? [String: Any])
        XCTAssertNil(acceptedBody["reason"])

        let data = try PropertyListSerialization.data(fromPropertyList: envelope, format: .binary, options: 0)
        let chunks = PixelWatchNotificationFraming.chunks(of: data, maximumUpdateValueLength: 20)
        XCTAssertEqual(chunks.first?.first.map { $0 & 0x01 }, UInt8(0x01))
        XCTAssertEqual(chunks.last?.first.map { $0 & 0x02 }, UInt8(0x02))
        let joined = chunks.reduce(into: Data()) { partial, chunk in
            partial.append(chunk.dropFirst(PixelWatchNotificationFraming.headerSize))
        }
        let decoded = try XCTUnwrap(PropertyListSerialization.propertyList(from: joined, options: [], format: nil) as? [String: Any])
        let decodedAck = try XCTUnwrap(decoded["ack"] as? [String: Any])
        XCTAssertEqual(decodedAck["status"] as? String, "rejected")
        XCTAssertEqual(decodedAck["requestId"] as? String, requestId.uuidString)
    }

    func testReceiptsRoundTripThroughUserDefaults() throws {
        let suite = "PixelWatchCommandProcessorTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        let receipt = PixelWatchCommandReceipt(
            requestId: UUID(),
            status: .rejected,
            reason: PixelWatchCommandReason.unknownPreset.rawValue,
            commandName: PixelWatchCommandName.presetStart.rawValue,
            receivedAt: now
        )
        try PixelWatchCommandProcessor.store([receipt], in: defaults)
        let loaded = try PixelWatchCommandProcessor.receipts(from: defaults)
        XCTAssertEqual(loaded, [receipt])

        defaults.set(Data("not-json".utf8), forKey: PixelWatchCommandProcessor.userDefaultsReceiptsKey)
        XCTAssertThrowsError(try PixelWatchCommandProcessor.receipts(from: defaults))
    }

    func testApplicatorUsesPhoneOverrideApisAndLeavesTheOtherOverrideAlone() {
        var settings = configuredSettings()
        let start = Date(timeIntervalSince1970: 1_700_000_100)
        XCTAssertTrue(PixelWatchOverrideApplicator.apply(.preMealStart(90 * 60), to: &settings, at: start))
        XCTAssertEqual(settings.preMealOverride?.startDate, start)
        XCTAssertEqual(settings.preMealOverride?.duration, .finite(90 * 60))
        XCTAssertEqual(settings.preMealOverride?.enactTrigger, .local)
        XCTAssertEqual(
            settings.preMealOverride?.settings.targetRange?.lowerBound.doubleValue(for: .milligramsPerDeciliter),
            80
        )
        XCTAssertEqual(
            settings.preMealOverride?.settings.targetRange?.upperBound.doubleValue(for: .milligramsPerDeciliter),
            90
        )
        XCTAssertNil(settings.scheduleOverride)

        let preset = settings.overridePresets[0]
        XCTAssertTrue(PixelWatchOverrideApplicator.apply(.presetStart(id: preset.id, duration: .finite(30 * 60)), to: &settings, at: start))
        XCTAssertNotNil(settings.preMealOverride)
        XCTAssertEqual(settings.scheduleOverride?.duration, .finite(30 * 60))
        XCTAssertEqual(settings.scheduleOverride?.enactTrigger, .local)
        if case .preset(let running) = settings.scheduleOverride?.context {
            XCTAssertEqual(running.id, preset.id)
        } else {
            XCTFail("Expected a preset schedule override")
        }

        XCTAssertTrue(PixelWatchOverrideApplicator.apply(.presetStop, to: &settings, at: start))
        XCTAssertNil(settings.scheduleOverride)
        XCTAssertNotNil(settings.preMealOverride)

        XCTAssertTrue(PixelWatchOverrideApplicator.apply(.preMealStop, to: &settings, at: start))
        XCTAssertNil(settings.preMealOverride)
    }

    func testApplicatorRefusesAMissingPresetWithoutChangingPreMeal() {
        var settings = configuredSettings()
        let start = Date(timeIntervalSince1970: 1_700_000_100)
        XCTAssertTrue(PixelWatchOverrideApplicator.apply(.preMealStart(60 * 60), to: &settings, at: start))
        XCTAssertFalse(PixelWatchOverrideApplicator.apply(.presetStart(id: UUID(), duration: .finite(60 * 60)), to: &settings, at: start))
        XCTAssertNil(settings.scheduleOverride)
        XCTAssertNotNil(settings.preMealOverride)

        var unconfigured = LoopSettings()
        XCTAssertFalse(PixelWatchOverrideApplicator.apply(.preMealStart(60 * 60), to: &unconfigured, at: start))
        XCTAssertNil(unconfigured.preMealOverride)
        XCTAssertFalse(PixelWatchOverrideApplicator.apply(.presetStart(id: presetID, duration: .finite(0)), to: &settings, at: start))

        var broken = configuredSettings(duration: .finite(0))
        XCTAssertTrue(PixelWatchOverrideApplicator.apply(.presetStart(id: presetID, duration: .finite(15 * 60)), to: &broken, at: start))
        XCTAssertEqual(broken.scheduleOverride?.duration, .finite(15 * 60))
        XCTAssertEqual(broken.scheduleOverride?.enactTrigger, .local)
    }

    func testWriteAssemblerRejectsGapsEmptyAndOversizeWrites() {
        XCTAssertEqual(PixelWatchWriteAssembler.assemble([]), .failure(.empty))
        XCTAssertEqual(PixelWatchWriteAssembler.assemble([(offset: 0, value: Data())]), .failure(.empty))
        XCTAssertEqual(PixelWatchWriteAssembler.assemble([(offset: 4, value: Data([0x01]))]), .failure(.gap))
        XCTAssertEqual(
            PixelWatchWriteAssembler.assemble([
                (offset: 0, value: Data([0x01])),
                (offset: 2, value: Data([0x02]))
            ]),
            .failure(.gap)
        )

        let limit = PixelWatchCommandProcessor.maxCommandBytes
        XCTAssertEqual(
            PixelWatchWriteAssembler.assemble([(offset: 0, value: Data(count: limit))]).map { $0.count },
            .success(limit)
        )
        XCTAssertEqual(
            PixelWatchWriteAssembler.assemble([(offset: 0, value: Data(count: limit + 1))]),
            .failure(.tooLarge)
        )

        let assembled = PixelWatchWriteAssembler.assemble([
            (offset: 2, value: Data([0x03, 0x04])),
            (offset: 0, value: Data([0x01, 0x02]))
        ])
        XCTAssertEqual(assembled, .success(Data([0x01, 0x02, 0x03, 0x04])))
    }

    func testCommandCharacteristicIsEncryptedWriteAndContextStaysNotifyOnly() {
        XCTAssertEqual(
            PixelWatchDataManager.commandUUID.uuidString.lowercased(),
            "c5d8a1e4-7b32-4f9a-8e16-0a4d5c7b9e21"
        )
        XCTAssertNotEqual(PixelWatchDataManager.commandUUID, PixelWatchDataManager.contextUUID)
        XCTAssertEqual(PixelWatchDataManager.commandProperties, [.write, .writeEncryptionRequired])
        XCTAssertFalse(PixelWatchDataManager.commandProperties.contains(.writeWithoutResponse))
        XCTAssertFalse(PixelWatchDataManager.commandProperties.contains(.authenticatedSignedWrites))
        XCTAssertFalse(PixelWatchDataManager.commandProperties.contains(.notify))
        XCTAssertEqual(PixelWatchDataManager.commandPermissions, [.writeable, .writeEncryptionRequired])
        XCTAssertTrue(PixelWatchDataManager.commandPermissions.contains(.writeable))
        XCTAssertTrue(PixelWatchDataManager.commandPermissions.contains(.writeEncryptionRequired))
        XCTAssertFalse(PixelWatchDataManager.commandPermissions.contains(.readable))
        XCTAssertEqual(PixelWatchDataManager.contextProperties, [.notifyEncryptionRequired])
        XCTAssertEqual(PixelWatchDataManager.contextPermissions, [])
        XCTAssertEqual(PixelWatchCommandProcessor.userDefaultsTestModeKey, "com.loopkit.Loop.PixelWatchCommandTestMode")
    }

    private func configuredSettings(duration: TemporaryScheduleOverride.Duration = .finite(60 * 60)) -> LoopSettings {
        var settings = LoopSettings()
        settings.preMealTargetRange = DoubleRange(minValue: 80, maxValue: 90).quantityRange(for: .milligramsPerDeciliter)
        settings.overridePresets = [
            TemporaryScheduleOverridePreset(
                id: presetID,
                symbol: "🏃",
                name: "Exercise",
                settings: TemporaryScheduleOverrideSettings(
                    unit: .milligramsPerDeciliter,
                    targetRange: DoubleRange(minValue: 140, maxValue: 160),
                    insulinNeedsScaleFactor: 0.8
                ),
                duration: duration
            )
        ]
        return settings
    }

    private func command(
        _ name: String,
        at timestamp: Date? = nil,
        requestId: UUID? = nil,
        presetId: UUID? = nil,
        presetIdString: String? = nil,
        durationSeconds: Double? = nil
    ) -> [String: Any] {
        var plist: [String: Any] = [
            "v": 1,
            "cmd": name,
            "requestId": (requestId ?? UUID()).uuidString,
            "timestamp": timestamp ?? now
        ]
        if let presetIdString = presetIdString {
            plist["presetId"] = presetIdString
        } else if let presetId = presetId {
            plist["presetId"] = presetId.uuidString
        }
        if let durationSeconds = durationSeconds {
            plist["durationSeconds"] = durationSeconds
        }
        return plist
    }
}
