//
//  PixelWatchActionsSnapshotTests.swift
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

class PixelWatchActionsSnapshotTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private let pumpDataDate = Date(timeIntervalSince1970: 1_699_999_000)
    private let glucoseDate = Date(timeIntervalSince1970: 1_699_999_500)

    func testEnvelopeKeepsVersionOneAndStripsCgmState() throws {
        let context = sampleContext(recommendedBolus: 0.4)
        context.cgmManagerState = ["secret": "strip-me"]
        let snapshot = makeSnapshot(context: context)

        XCTAssertEqual(snapshot.fullEnvelope["v"] as? Int, PixelWatchActionsSnapshot.envelopeVersion)
        XCTAssertEqual(snapshot.legacyEnvelope["v"] as? Int, 1)
        XCTAssertEqual(Set(snapshot.legacyEnvelope.keys), Set(["v", "ctx", "hg"]))
        XCTAssertEqual(Set(snapshot.fullEnvelope.keys), Set(["v", "ctx", "hg", "act"]))

        let ctx = snapshot.fullEnvelope["ctx"] as! [String: Any]
        XCTAssertNil(ctx["cgmManagerState"])
        XCTAssertEqual(ctx["rbo"] as? Double, 0.4)
        XCTAssertEqual(ctx["v"] as? Int, 5)
        XCTAssertEqual(snapshot.fullEnvelope["hg"] as? [[Double]], [[1_700_000_000, 118]])

        let actions = self.actions(snapshot)
        XCTAssertEqual(actions["v"] as? Int, PixelWatchActionsSnapshot.actionsSchemaVersion)
        let cap = try XCTUnwrap(actions["cap"] as? [String: Bool])
        XCTAssertEqual(cap, [
            "preMeal": false,
            "workout": false,
            "carbs": false,
            "bolus": false
        ])
    }

    func testPresetsIncludeIdentitySymbolDurationAndOptionalTarget() {
        let ranged = TemporaryScheduleOverridePreset(
            id: UUID(uuidString: "2F1C0A7E-6B4D-4E2A-9C11-8A0B1C2D3E4F")!,
            symbol: "🏃",
            name: "Exercise",
            settings: TemporaryScheduleOverrideSettings(
                unit: .milligramsPerDeciliter,
                targetRange: DoubleRange(minValue: 140, maxValue: 160),
                insulinNeedsScaleFactor: 0.8
            ),
            duration: .finite(60 * 60)
        )
        let percentageOnly = TemporaryScheduleOverridePreset(
            symbol: "🤒",
            name: "Sick",
            settings: TemporaryScheduleOverrideSettings(targetRange: nil, insulinNeedsScaleFactor: 0.5),
            duration: .indefinite
        )
        var settings = LoopSettings()
        settings.overridePresets = [ranged, percentageOnly]

        let presets = actions(makeSnapshot(settings: settings))["presets"] as! [[String: Any]]
        XCTAssertEqual(presets.count, 2)
        XCTAssertEqual(actions(makeSnapshot(settings: settings))["presetsTruncated"] as? Bool, false)

        XCTAssertEqual(presets[0]["id"] as? String, "2F1C0A7E-6B4D-4E2A-9C11-8A0B1C2D3E4F")
        XCTAssertEqual(presets[0]["name"] as? String, "Exercise")
        XCTAssertEqual(presets[0]["symbol"] as? String, "🏃")
        XCTAssertEqual(presets[0]["indefinite"] as? Bool, false)
        XCTAssertEqual(presets[0]["durationSeconds"] as? Double, 3600)
        XCTAssertEqual(presets[0]["targetLowerMgdl"] as? Double, 140)
        XCTAssertEqual(presets[0]["targetUpperMgdl"] as? Double, 160)
        XCTAssertEqual(presets[0]["insulinNeedsScaleFactor"] as? Double, 0.8)

        XCTAssertEqual(presets[1]["name"] as? String, "Sick")
        XCTAssertEqual(presets[1]["indefinite"] as? Bool, true)
        XCTAssertNil(presets[1]["durationSeconds"])
        XCTAssertNil(presets[1]["targetLowerMgdl"])
        XCTAssertNil(presets[1]["targetUpperMgdl"])
        XCTAssertEqual(presets[1]["insulinNeedsScaleFactor"] as? Double, 0.5)
    }

    func testPresetListCapsAtSixteenInListOrder() {
        var settings = LoopSettings()
        settings.overridePresets = (0..<17).map { index in
            TemporaryScheduleOverridePreset(
                symbol: "•",
                name: "P\(index)",
                settings: TemporaryScheduleOverrideSettings(targetRange: nil),
                duration: .finite(3600)
            )
        }

        let actions = self.actions(makeSnapshot(settings: settings))
        let names = (actions["presets"] as! [[String: Any]]).compactMap { $0["name"] as? String }
        XCTAssertEqual(names, (0..<16).map { "P\($0)" })
        XCTAssertEqual(actions["presetsTruncated"] as? Bool, true)
    }

    func testActivePresetOverrideAndFinishedOverride() {
        let preset = TemporaryScheduleOverridePreset(
            id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
            symbol: "🏃",
            name: "Exercise",
            settings: TemporaryScheduleOverrideSettings(
                unit: .milligramsPerDeciliter,
                targetRange: DoubleRange(minValue: 140, maxValue: 160),
                insulinNeedsScaleFactor: 0.8
            ),
            duration: .finite(60 * 60)
        )
        let start = now.addingTimeInterval(-10 * 60)
        var settings = LoopSettings()
        settings.overridePresets = [preset]
        settings.scheduleOverride = preset.createOverride(enactTrigger: .local, beginningAt: start)

        let active = actions(makeSnapshot(settings: settings))["override"] as! [String: Any]
        XCTAssertEqual(active["kind"] as? String, "preset")
        XCTAssertEqual(active["presetId"] as? String, preset.id.uuidString)
        XCTAssertEqual(active["name"] as? String, "Exercise")
        XCTAssertEqual(active["symbol"] as? String, "🏃")
        XCTAssertEqual(active["active"] as? Bool, true)
        XCTAssertEqual(active["indefinite"] as? Bool, false)
        assertDate(active["start"], equals: start)
        assertDate(active["end"], equals: start.addingTimeInterval(3600))
        XCTAssertEqual(active["targetLowerMgdl"] as? Double, 140)
        XCTAssertEqual(active["insulinNeedsScaleFactor"] as? Double, 0.8)

        settings.scheduleOverride = preset.createOverride(enactTrigger: .local, beginningAt: now.addingTimeInterval(-2 * 60 * 60))
        XCTAssertNil(actions(makeSnapshot(settings: settings))["override"])
    }

    func testCustomFutureLegacyAndDeletedOverrides() throws {
        var settings = LoopSettings()
        let futureStart = now.addingTimeInterval(30 * 60)
        settings.scheduleOverride = TemporaryScheduleOverride(
            context: .custom,
            settings: TemporaryScheduleOverrideSettings(
                unit: .milligramsPerDeciliter,
                targetRange: DoubleRange(minValue: 100, maxValue: 110)
            ),
            startDate: futureStart,
            duration: .finite(30 * 60),
            enactTrigger: .local,
            syncIdentifier: UUID()
        )
        let future = actions(makeSnapshot(settings: settings))["override"] as! [String: Any]
        XCTAssertEqual(future["kind"] as? String, "custom")
        XCTAssertNil(future["presetId"])
        XCTAssertEqual(future["active"] as? Bool, false)
        assertDate(future["start"], equals: futureStart)

        settings.scheduleOverride = TemporaryScheduleOverride(
            context: .legacyWorkout,
            settings: TemporaryScheduleOverrideSettings(
                unit: .milligramsPerDeciliter,
                targetRange: DoubleRange(minValue: 130, maxValue: 150)
            ),
            startDate: now.addingTimeInterval(-60),
            duration: .indefinite,
            enactTrigger: .local,
            syncIdentifier: UUID()
        )
        let legacy = actions(makeSnapshot(settings: settings))["override"] as! [String: Any]
        XCTAssertEqual(legacy["kind"] as? String, "legacyWorkout")
        XCTAssertNil(legacy["presetId"])
        XCTAssertEqual(legacy["active"] as? Bool, true)
        XCTAssertEqual(legacy["indefinite"] as? Bool, true)
        XCTAssertNil(legacy["end"])
        XCTAssertEqual(legacy["targetLowerMgdl"] as? Double, 130)
        XCTAssertEqual(legacy["targetUpperMgdl"] as? Double, 150)

        var deleted = try XCTUnwrap(settings.scheduleOverride)
        deleted.actualEnd = .deleted
        settings.scheduleOverride = deleted
        XCTAssertNil(actions(makeSnapshot(settings: settings))["override"])
    }

    func testPreMealAvailabilityAndActiveWindow() {
        let unavailable = actions(makeSnapshot())["preMeal"] as! [String: Any]
        XCTAssertEqual(unavailable["available"] as? Bool, false)
        XCTAssertEqual(unavailable["active"] as? Bool, false)
        XCTAssertNil(unavailable["targetLowerMgdl"])
        XCTAssertNil(unavailable["start"])

        var settings = LoopSettings()
        settings.preMealTargetRange = DoubleRange(minValue: 80, maxValue: 90).quantityRange(for: .milligramsPerDeciliter)
        let configured = actions(makeSnapshot(settings: settings))["preMeal"] as! [String: Any]
        XCTAssertEqual(configured["available"] as? Bool, true)
        XCTAssertEqual(configured["active"] as? Bool, false)
        XCTAssertEqual(configured["targetLowerMgdl"] as? Double, 80)
        XCTAssertEqual(configured["targetUpperMgdl"] as? Double, 90)
        XCTAssertNil(configured["start"])

        let start = now.addingTimeInterval(-5 * 60)
        settings.enablePreMealOverride(at: start, for: 60 * 60)
        let active = actions(makeSnapshot(settings: settings))["preMeal"] as! [String: Any]
        XCTAssertEqual(active["available"] as? Bool, true)
        XCTAssertEqual(active["active"] as? Bool, true)
        XCTAssertEqual(active["indefinite"] as? Bool, false)
        assertDate(active["start"], equals: start)
        assertDate(active["end"], equals: start.addingTimeInterval(3600))
        XCTAssertEqual(active["targetLowerMgdl"] as? Double, 80)
    }

    func testPreMealAndScheduleOverrideAreBothReported() {
        let preset = TemporaryScheduleOverridePreset(
            symbol: "🏃",
            name: "Exercise",
            settings: TemporaryScheduleOverrideSettings(targetRange: nil, insulinNeedsScaleFactor: 0.7),
            duration: .finite(60 * 60)
        )
        var settings = LoopSettings()
        settings.preMealTargetRange = DoubleRange(minValue: 80, maxValue: 80).quantityRange(for: .milligramsPerDeciliter)
        settings.enablePreMealOverride(at: now.addingTimeInterval(-60), for: 60 * 60)
        settings.overridePresets = [preset]
        settings.scheduleOverride = preset.createOverride(enactTrigger: .local, beginningAt: now.addingTimeInterval(-60))

        let actions = self.actions(makeSnapshot(settings: settings))
        let preMeal = actions["preMeal"] as! [String: Any]
        let schedule = actions["override"] as! [String: Any]
        XCTAssertEqual(preMeal["active"] as? Bool, true)
        XCTAssertEqual(schedule["kind"] as? String, "preset")
        XCTAssertEqual(schedule["active"] as? Bool, true)
    }

    func testLimitsAndBolusFreshness() {
        var settings = LoopSettings()
        settings.maximumBolus = 6.5
        let context = sampleContext(recommendedBolus: 0.55)
        let actions = self.actions(makeSnapshot(context: context, settings: settings))

        let limits = actions["limits"] as! [String: Any]
        XCTAssertEqual(limits["maximumBolus"] as? Double, 6.5)
        XCTAssertEqual(limits["maxCarbGrams"] as? Double, LoopConstants.maxCarbEntryQuantity.doubleValue(for: .gram()))
        XCTAssertEqual(limits["minCarbAbsorptionSeconds"] as? TimeInterval, LoopConstants.minCarbAbsorptionTime)
        XCTAssertEqual(limits["maxCarbAbsorptionSeconds"] as? TimeInterval, LoopConstants.maxCarbAbsorptionTime)
        XCTAssertEqual(limits["defaultCarbAbsorptionSeconds"] as? TimeInterval, 3 * 60 * 60)
        XCTAssertEqual(limits["carbEntryPastSeconds"] as? TimeInterval, LoopConstants.maxCarbEntryPastTime)
        XCTAssertEqual(limits["carbEntryFutureSeconds"] as? TimeInterval, LoopConstants.maxCarbEntryFutureTime)
        XCTAssertEqual(limits["inputDataRecencySeconds"] as? TimeInterval, LoopCoreConstants.inputDataRecencyInterval)
        XCTAssertEqual(limits["maxOverrideDurationSeconds"] as? TimeInterval, LoopConstants.maxOverrideDurationTime)
        XCTAssertLessThan(limits["carbEntryPastSeconds"] as! TimeInterval, 0)

        let bolus = actions["bolus"] as! [String: Any]
        XCTAssertEqual(bolus["recommendedUnits"] as? Double, 0.55)
        assertDate(bolus["snapshotDate"], equals: context.creationDate)
        assertDate(bolus["glucoseDate"], equals: glucoseDate)
        assertDate(bolus["pumpDataDate"], equals: pumpDataDate)

        let missing = self.actions(makeSnapshot())["limits"] as! [String: Any]
        XCTAssertNil(missing["maximumBolus"])
        let noRecommendation = self.actions(makeSnapshot())["bolus"] as! [String: Any]
        XCTAssertNil(noRecommendation["recommendedUnits"])
        XCTAssertNil(noRecommendation["glucoseDate"])
        XCTAssertNotNil(noRecommendation["snapshotDate"])
        XCTAssertNotNil(noRecommendation["pumpDataDate"])
    }

    func testPayloadShedsPresetsThenActionsToStayInsideChunkBudget() throws {
        var settings = LoopSettings()
        settings.overridePresets = [
            TemporaryScheduleOverridePreset(
                symbol: "🏃",
                name: String(repeating: "Exercise", count: 40),
                settings: TemporaryScheduleOverrideSettings(
                    unit: .milligramsPerDeciliter,
                    targetRange: DoubleRange(minValue: 140, maxValue: 160),
                    insulinNeedsScaleFactor: 0.8
                ),
                duration: .finite(60 * 60)
            )
        ]
        let snapshot = makeSnapshot(settings: settings)
        let mtu = 20

        let fullCount = try chunkCount(snapshot.fullEnvelope, mtu: mtu)
        let omittedCount = try chunkCount(snapshot.presetsOmittedEnvelope, mtu: mtu)
        let legacyCount = try chunkCount(snapshot.legacyEnvelope, mtu: mtu)
        XCTAssertGreaterThan(fullCount, omittedCount)
        XCTAssertGreaterThan(omittedCount, legacyCount)

        let presetsDropped = try XCTUnwrap(snapshot.framedPayload(maximumUpdateValueLength: mtu, maxChunks: omittedCount))
        XCTAssertEqual(presetsDropped.kind, .presetsOmitted)
        let droppedAct = try XCTUnwrap(try plist(from: presetsDropped)["act"] as? [String: Any])
        XCTAssertEqual(boolValue(droppedAct["presetsTruncated"]), true)
        XCTAssertNil(droppedAct["presets"])
        XCTAssertNotNil(droppedAct["cap"])

        let actionsDropped = try XCTUnwrap(snapshot.framedPayload(maximumUpdateValueLength: mtu, maxChunks: legacyCount))
        XCTAssertEqual(actionsDropped.kind, .actionsOmitted)
        let legacyPlist = try plist(from: actionsDropped)
        XCTAssertNil(legacyPlist["act"])
        XCTAssertEqual(intValue(legacyPlist["v"]), 1)
        XCTAssertNotNil(legacyPlist["ctx"])
        XCTAssertNotNil(legacyPlist["hg"])

        let full = try XCTUnwrap(snapshot.framedPayload(maximumUpdateValueLength: 512, maxChunks: 10_000))
        XCTAssertEqual(full.kind, .full)
        XCTAssertLessThanOrEqual(full.chunks.count, PixelWatchNotificationFraming.maxChunks)
        XCTAssertEqual(full.chunks.first?.first.map { $0 & 0x01 }, UInt8(0x01))
        XCTAssertEqual(full.chunks.last?.first.map { $0 & 0x02 }, UInt8(0x02))
        let fullAct = try XCTUnwrap(try plist(from: full)["act"] as? [String: Any])
        let cap = try XCTUnwrap(fullAct["cap"] as? [String: Any])
        for key in ["preMeal", "workout", "carbs", "bolus"] {
            XCTAssertEqual(boolValue(cap[key]), false, key)
        }
    }

    func testNotificationFramingFlagsAndSequence() {
        let envelope = Data(repeating: 0xAB, count: 40)
        let chunks = PixelWatchNotificationFraming.chunks(of: envelope, maximumUpdateValueLength: 20)
        XCTAssertEqual(chunks.count, 3)
        XCTAssertEqual([UInt8](chunks[0].prefix(2)), [0x01, 0])
        XCTAssertEqual([UInt8](chunks[1].prefix(2)), [0x00, 1])
        XCTAssertEqual([UInt8](chunks[2].prefix(2)), [0x02, 2])
        XCTAssertEqual(chunks[0].count, 20)
        XCTAssertEqual(chunks[2].dropFirst(2), Data(repeating: 0xAB, count: 4))

        let single = PixelWatchNotificationFraming.chunks(of: Data([0x01]), maximumUpdateValueLength: 512)
        XCTAssertEqual(single.count, 1)
        XCTAssertEqual([UInt8](single[0].prefix(2)), [0x03, 0])
    }

    func testContextCharacteristicStaysNotifyOnly() {
        let writable: CBCharacteristicProperties = [.write, .writeWithoutResponse, .authenticatedSignedWrites]
        XCTAssertEqual(PixelWatchDataManager.contextProperties, [.notifyEncryptionRequired])
        XCTAssertTrue(PixelWatchDataManager.contextProperties.intersection(writable).isEmpty)
        XCTAssertEqual(PixelWatchDataManager.contextPermissions, [])
        XCTAssertFalse(PixelWatchDataManager.contextPermissions.contains(.write))
        XCTAssertFalse(PixelWatchDataManager.contextPermissions.contains(.writeEncryptionRequired))
        XCTAssertFalse(PixelWatchDataManager.contextPermissions.contains(.read))
    }

    private func sampleContext(recommendedBolus: Double?) -> WatchContext {
        let context = WatchContext()
        context.creationDate = now
        context.glucoseDate = glucoseDate
        context.recommendedBolusDose = recommendedBolus
        return context
    }

    private func makeSnapshot(
        context: WatchContext? = nil,
        settings: LoopSettings = LoopSettings(),
        history: [[Double]] = [[1_700_000_000, 118]]
    ) -> PixelWatchActionsSnapshot {
        PixelWatchActionsSnapshot.make(
            context: context ?? sampleContext(recommendedBolus: nil),
            glucoseHistory: history,
            settings: settings,
            pumpDataDate: pumpDataDate,
            defaultCarbAbsorption: 3 * 60 * 60,
            now: now
        )
    }

    private func actions(_ snapshot: PixelWatchActionsSnapshot) -> [String: Any] {
        snapshot.fullEnvelope["act"] as! [String: Any]
    }

    private func chunkCount(_ plist: [String: Any], mtu: Int) throws -> Int {
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
        return PixelWatchNotificationFraming.chunks(of: data, maximumUpdateValueLength: mtu).count
    }

    private func plist(from payload: PixelWatchFramedPayload) throws -> [String: Any] {
        let data = payload.chunks.reduce(into: Data()) { partial, chunk in
            partial.append(chunk.dropFirst(PixelWatchNotificationFraming.headerSize))
        }
        return try XCTUnwrap(PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any])
    }

    private func assertDate(_ value: Any?, equals expected: Date, file: StaticString = #file, line: UInt = #line) {
        XCTAssertEqual(
            (value as? Date)?.timeIntervalSinceReferenceDate ?? .nan,
            expected.timeIntervalSinceReferenceDate,
            accuracy: 0.001,
            file: file,
            line: line
        )
    }

    private func boolValue(_ value: Any?) -> Bool? {
        if let value = value as? Bool {
            return value
        }
        if let number = value as? NSNumber {
            return number.boolValue
        }
        return nil
    }

    private func intValue(_ value: Any?) -> Int? {
        if let value = value as? Int {
            return value
        }
        if let number = value as? NSNumber {
            return number.intValue
        }
        return nil
    }
}
