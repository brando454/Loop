# Pixel Watch status protocol

Status snapshot and override commands Loop exchanges with a bonded Wear OS watch (Loop Wrist). The phone is the only dosing authority. This document is the contract for the watch. The notify payload is the actions snapshot. The write payload is a Pre-Meal or named-preset override command. This build does not accept carb or bolus commands.

## Transport

One service. Two characteristics. Link encryption is the existing iPhone bond (the same bond the notify path already required). There is no second app-level key.

| | Context | Command |
|---|---|---|
| Service | `354E12EF-6EA4-4255-B054-9D2A113E2C8D` | same service |
| Characteristic | `219E7627-1F0C-4D0C-951F-FDC44514B868` | `C5D8A1E4-7B32-4F9A-8E16-0A4D5C7B9E21` |
| Properties | Notify, encryption required | Write, write encryption required |
| Permissions | None. Not readable and not writable. | Write encryption required only. There is no unencrypted write permission. |
| Direction | Phone to watch | Watch to phone |

A peer that is not bonded cannot subscribe and cannot write. Core Bluetooth rejects an unencrypted write before Loop sees the bytes.

The command characteristic is new. After this build is installed, the watch has to disconnect and reconnect once so it discovers the write characteristic. A restored GATT service from the previous build had notify only; Loop drops that service and publishes both characteristics.

Writes are Write With Response. There is no write-without-response. Do not put the notify framing bytes on the write. One command is one binary property list. If it is larger than the ATT MTU, the watch uses a normal BLE long write (prepare/execute). Loop reassembles the parts by offset. The command must be at most 2048 bytes, must start at offset 0, and must not have gaps or empty parts.

| Write problem | ATT result | Ack |
|---|---|---|
| Not the command characteristic | Write Not Permitted | none |
| Offset gap, or the first byte is not at offset 0 | Invalid Offset | none |
| Empty value, or more than 2048 bytes | Invalid Attribute Value Length | none |
| Bytes accepted | Success | a notify ack, then a snapshot |

ATT success means Loop accepted the bytes. It does not mean the override changed. The ack is the result. Loop does not retry a command, and the watch must not retry a command by writing the same `requestId` again in order to apply it a second time. Writing that same id again within 24 hours only repeats the original ack.

### Framing

Each notification is:

| Offset | Size | Meaning |
|---|---|---|
| 0 | 1 | Flags. Bit 0 = first chunk of a message. Bit 1 = last chunk. |
| 1 | 1 | Sequence number within the message, starting at 0, wrapping as `UInt8`. |
| 2 | rest | Payload bytes |

The watch resets reassembly when it sees the first-chunk flag, appends payloads in sequence order, and parses when it sees the last-chunk flag. A gap in the sequence drops the message. A newer message may replace one that has not finished; the next first-chunk flag starts over. That new message may be an ack or a snapshot. Tell them apart by the top-level key: `ack` is a command result, `ctx` is a snapshot.

The sequence byte gives a message at most 256 chunks. Chunk size is `max(18, maximumUpdateValueLength - 2)` bytes of payload. On a negotiated ATT MTU this is plenty. On a 20-byte link the budget is about 4.5 KB. If the full snapshot would exceed 256 chunks, the phone sends the same envelope without the preset list (`presetsTruncated` true, `presets` omitted). If that still does not fit, it sends the original envelope (`v`, `ctx`, `hg` only) and leaves `act` out. The watch treats a missing `act` as "no actions metadata" (every capability false), not as an empty preset list.

## Versioning

These version numbers are not interchangeable.

| Field | Current | What it versions |
|---|---|---|
| Envelope `v` | `1` | `ctx` and `hg` on a snapshot. The same `1` is the top-level version of an ack message. Left at 1 so a watch that already reads `ctx` and `hg` keeps working. |
| `ctx.v` | `5` | `WatchContext`, shared with the Apple Watch. This payload does not change it. |
| `act.v` | `1` | The actions snapshot described below. |
| Command `v` | `1` | The write plist. Independent of `act.v`. |

Rules for the watch:

- Ignore unknown keys at every level.
- Keep parsing `ctx` and `hg` for any envelope `v` that still includes them. Do not require `act`.
- Read `act` only when it is present. If `act.v` is newer than the watch understands, keep using the keys this document defines and ignore the rest.
- A missing capability key means false.

Bump `act.v` when an existing actions field changes meaning. Adding a key does not require a bump. Bump envelope `v` only when `ctx` or `hg` change meaning.

## Envelope

Snapshot messages are a binary property list. An ack is a different plist and does not include `ctx`. Top-level dictionary:

| Key | Type | Required | Meaning |
|---|---|---|---|
| `v` | Int | yes | Envelope version. `1`. |
| `ctx` | Dictionary | yes | `WatchContext` raw value with `cgmManagerState` removed. |
| `hg` | Array of `[Double, Double]` | yes | Glucose history. Empty array when no samples were returned. |
| `act` | Dictionary | no | Actions snapshot. Absent on older phones and when the payload had to be shrunk to the chunk budget. |

`hg` points are `[seconds since 1970-01-01 UTC, mg/dL]`. These are numbers, not property-list dates. History is the last 3 hours. The display glucose inside `ctx` (`gv`) is in the unit named by `ctx.gu`, which may be mg/dL or mmol/L. `hg` and every `*Mgdl` field below are always mg/dL.

### `ctx` fields the watch already uses

`ctx` is still the Apple Watch context (version 5). Dates inside it are binary-plist dates (the same type Core Bluetooth watch parsers already turn into an instant for `cd`, `gd`, and `ld`). They are not strings and not epoch numbers.

| Key | Type | Unit | Meaning |
|---|---|---|---|
| `v` | Int | | WatchContext version, currently 5. |
| `cd` | Date | instant | When this context was built. Same instant as `act.bolus.snapshotDate`. |
| `gv` | Double | `gu` | Latest glucose, in the display unit. |
| `gu` | String | | Display unit string, `mg/dL` or `mmol/L`. |
| `gd` | Date | instant | Glucose sample time. Same instant as `act.bolus.glucoseDate`. Omitted when unknown. |
| `gt` | Int | | Glucose trend raw value. |
| `iob` | Double | U | Insulin on board. |
| `cob` | Double | g | Carbs on board. |
| `ba` | Double | U/hr | Last net temporary basal. |
| `cl` | Bool | | Closed loop enabled. |
| `ld` | Date | instant | Last loop completion. |
| `pg` | Dictionary | | Predicted glucose. |
| `rbo` | Double | U | Recommended bolus. Omitted when Loop declined to recommend one. Same number as `act.bolus.recommendedUnits`. |

`rbo` was already on this characteristic. The actions block repeats it next to the timestamps the watch needs for staleness. Loop computes it in `WatchDataManager.createWatchContext` via `recommendBolus`. A missing `rbo` means there is no recommendation. It does not mean zero units.

## `act` (schema version 1)

| Key | Type | Required | Meaning |
|---|---|---|---|
| `v` | Int | yes | Actions schema version. `1`. |
| `cap` | Dictionary | yes | Which commands this phone will accept. |
| `presets` | Array of dictionaries | no | Override presets, Loop's list order, at most 16. Omitted when dropped for size. |
| `presetsTruncated` | Bool | yes | `true` when `presets` is not the full list (capped, or omitted for size). |
| `override` | Dictionary | no | Unfinished schedule override. Omitted when none is running or scheduled. |
| `preMeal` | Dictionary | yes | Whether Pre-Meal is configured and whether it is on. |
| `limits` | Dictionary | yes | Bolus and carb limits Loop enforces. |
| `bolus` | Dictionary | yes | Recommended bolus and the input timestamps behind it. |

`presetsTruncated` false and `presets` present (possibly empty) means the watch has the complete list. `presetsTruncated` true and `presets` absent means the list was not sent; do not draw that as "no presets". `presetsTruncated` true and `presets` present means the first 16 presets were sent and Loop has more.

### `cap`

| Key | Type | This build | Command |
|---|---|---|---|
| `preMeal` | Bool | `true` | `preMeal.start` and `preMeal.stop`. |
| `workout` | Bool | `true` | `preset.start` and `preset.stop`. |
| `carbs` | Bool | `false` | Store a carb entry. Still refused. |
| `bolus` | Bool | `false` | Enact a bolus. Still refused. |

`false`, or a missing key, means the phone does not accept that command. The watch writes a command only when the matching capability in the latest snapshot is `true`. `cap` stays `true` while no-dose test mode is on; the ack reason `testMode` is what says the phone did not change settings.

### `presets[]`

One entry per `LoopSettings.overridePresets` item, capped at 16, original order kept.

| Key | Type | Unit | Present |
|---|---|---|---|
| `id` | String | UUID | always. `UUID.uuidString` (uppercase). Compare case-insensitively. |
| `name` | String | | always. The preset name Loop stores. |
| `symbol` | String | | always. Emoji or other short symbol Loop stores. |
| `indefinite` | Bool | | always. `true` when the stored duration is indefinite. |
| `durationSeconds` | Double | seconds | only when `indefinite` is false. The preset's default duration, greater than 0. |
| `targetLowerMgdl` | Double | mg/dL | only when the preset sets a glucose target. |
| `targetUpperMgdl` | Double | mg/dL | paired with `targetLowerMgdl`. May equal the lower bound. |
| `insulinNeedsScaleFactor` | Double | unitless | only when the preset sets one. Omitted means no change (factor 1). |

`insulinNeedsScaleFactor` is Loop's insulin-needs multiplier. `0.8` means 80% of usual insulin need: basal is multiplied by 0.8, and insulin sensitivity and carb ratio are multiplied by `1 / 0.8`. It is not a percent integer.

Targets are mg/dL even when `ctx.gu` is mmol/L. Convert for display the same way the watch converts an mg/dL glucose (HealthKit's mg/dL to mmol/L factor, about 18.0182).

### `override`

The current `scheduleOverride` when it has not finished and has not been deleted. This is the workout / custom override, not Pre-Meal. A future start is included with `active` false (Loop shows it as scheduled). A finished override is omitted. Pre-Meal is never reported here in normal use; it has its own object.

| Key | Type | Unit | Present |
|---|---|---|---|
| `kind` | String | | always. `preset`, `custom`, or `legacyWorkout`. |
| `presetId` | String | UUID | `kind` = `preset` only. Id of the preset captured when the override was started. It may be missing from `presets` if that preset was edited or deleted afterward, or if the list was truncated. |
| `name` | String | | `kind` = `preset` only. Name captured on the running override. |
| `symbol` | String | | `kind` = `preset` only. |
| `active` | Bool | | always. `true` when the override is in effect at send time. `false` when it is scheduled and has not started. |
| `start` | Date | instant | always. Binary-plist date. |
| `indefinite` | Bool | | always. `true` only when there is no concrete end. |
| `end` | Date | instant | when `indefinite` is false. When the override will end, including an early end Loop has already recorded. |
| `targetLowerMgdl` | Double | mg/dL | when the running override has a target. |
| `targetUpperMgdl` | Double | mg/dL | paired with the lower bound. |
| `insulinNeedsScaleFactor` | Double | unitless | when the running override has one. Same meaning as on a preset. |

`legacyWorkout` is the older workout target, not a named preset. It has no `presetId`. `custom` is an override that is not a saved preset.

When both `override` and an active `preMeal` are present, Loop uses the pre-meal target as the effective glucose target until the pre-meal override's scheduled end, then the schedule override (`LoopSettings.effectiveGlucoseTargetRangeSchedule`). The watch should show both; it should not merge them.

### `preMeal`

| Key | Type | Unit | Present |
|---|---|---|---|
| `available` | Bool | | always. `true` when a pre-meal target is stored (`preMealTargetRange` is set). `false` means the phone has nothing for Pre-Meal to turn on. |
| `active` | Bool | | always. `true` when that override is in effect now. |
| `targetLowerMgdl` | Double | mg/dL | when `available`. The stored target, not a value the watch chose. |
| `targetUpperMgdl` | Double | mg/dL | paired with the lower bound. |
| `start` | Date | instant | when an unfinished pre-meal override exists. |
| `end` | Date | instant | when that override has a finite end. |
| `indefinite` | Bool | | when an unfinished pre-meal override exists. Pre-Meal is started for a finite duration; this is false in practice. |

There is no stored pre-meal duration. The duration is chosen when it is turned on. `start` and `end` describe the one that is running or scheduled. The targets are the stored range. If someone edits the stored range while Pre-Meal is already running, the running override keeps the range it started with until it ends; `targetLowerMgdl` / `targetUpperMgdl` stay the stored range.

### `limits`

Copied from the limits Loop enforces on the phone at send time. The watch should display these and must not treat them as permission to dose. Grams must be greater than 0. Absorption and start windows below are what `LoopDataManager.deliverCarbs` rejects outside of. `maximumBolus` unset means Loop has no bolus cap configured; remote bolus on the phone refuses to run in that case.

| Key | Type | Unit | Present | Current source value |
|---|---|---|---|---|
| `maximumBolus` | Double | U (insulin units) | only when configured | whatever is saved in settings. Omitted when nil. |
| `maxCarbGrams` | Double | grams | always | 250 |
| `minCarbAbsorptionSeconds` | Double | seconds | always | 1800 (30 minutes) |
| `maxCarbAbsorptionSeconds` | Double | seconds | always | 28800 (8 hours) |
| `defaultCarbAbsorptionSeconds` | Double | seconds | always | the carb store's medium absorption (3 hours unless the user changed it) |
| `carbEntryPastSeconds` | Double | seconds | always | -43200 (−12 hours from now) |
| `carbEntryFutureSeconds` | Double | seconds | always | 3600 (+1 hour from now) |
| `inputDataRecencySeconds` | Double | seconds | always | 900 (15 minutes) |
| `maxOverrideDurationSeconds` | Double | seconds | always | 86400 (24 hours). A duration of 0 on Loop's remote override path means indefinite; indefinite presets are already represented by `indefinite: true`. |

The phone UI also warns above 99 g of carb. That warning is not a rejection and is not in this payload.

`inputDataRecencySeconds` is the interval Loop uses when it decides glucose or pump data are too old to recommend a bolus (`LoopCoreConstants.inputDataRecencyInterval`). The watch can mark the recommendation stale when `now - glucoseDate` or `now - pumpDataDate` is greater than this, or when either date is missing. The phone remains the authority if a command exists later.

### `bolus`

| Key | Type | Unit | Present |
|---|---|---|---|
| `recommendedUnits` | Double | U | when `ctx.rbo` is present. Same value. Omitted when Loop produced no recommendation. Never means "bolus zero" by itself; an explicit `0` would be a recommendation of zero units. |
| `snapshotDate` | Date | instant | always. `ctx.cd`. When this recommendation was evaluated. |
| `glucoseDate` | Date | instant | when `ctx.gd` is present. The glucose sample the context is showing. |
| `pumpDataDate` | Date | instant | always. `DoseStore.lastAddedPumpData`: the later of the latest reservoir reading and the latest pump-event reconciliation. With no pump data this is a date far in the past (`distantPast`), which is stale. |

`snapshotDate` is not the glucose time. Show staleness from `glucoseDate` and `pumpDataDate` against `inputDataRecencySeconds`. `ctx.ld` is still the last loop completion if the watch wants that too.

## Example

Logical contents. On the wire this is a binary property list: dates are plist dates (not the strings shown here), `hg` values are numbers, and bools are bools.

```json
{
  "v": 1,
  "ctx": {
    "v": 5,
    "cd": "2026-10-26T03:00:00Z",
    "gv": 118,
    "gu": "mg/dL",
    "gd": "2026-10-26T02:58:00Z",
    "ld": "2026-10-26T02:57:30Z",
    "rbo": 0.5,
    "iob": 1.2,
    "cob": 20,
    "cl": true
  },
  "hg": [[1761447480, 110], [1761447780, 118]],
  "act": {
    "v": 1,
    "cap": { "preMeal": true, "workout": true, "carbs": false, "bolus": false },
    "presets": [
      {
        "id": "2F1C0A7E-6B4D-4E2A-9C11-8A0B1C2D3E4F",
        "name": "Exercise",
        "symbol": "🏃",
        "indefinite": false,
        "durationSeconds": 3600,
        "targetLowerMgdl": 140,
        "targetUpperMgdl": 160,
        "insulinNeedsScaleFactor": 0.8
      }
    ],
    "presetsTruncated": false,
    "override": {
      "kind": "preset",
      "presetId": "2F1C0A7E-6B4D-4E2A-9C11-8A0B1C2D3E4F",
      "name": "Exercise",
      "symbol": "🏃",
      "active": true,
      "start": "2026-10-26T02:30:00Z",
      "end": "2026-10-26T03:30:00Z",
      "indefinite": false,
      "targetLowerMgdl": 140,
      "targetUpperMgdl": 160,
      "insulinNeedsScaleFactor": 0.8
    },
    "preMeal": {
      "available": true,
      "active": false,
      "targetLowerMgdl": 80,
      "targetUpperMgdl": 90
    },
    "limits": {
      "maximumBolus": 5,
      "maxCarbGrams": 250,
      "minCarbAbsorptionSeconds": 1800,
      "maxCarbAbsorptionSeconds": 28800,
      "defaultCarbAbsorptionSeconds": 10800,
      "carbEntryPastSeconds": -43200,
      "carbEntryFutureSeconds": 3600,
      "inputDataRecencySeconds": 900,
      "maxOverrideDurationSeconds": 86400
    },
    "bolus": {
      "recommendedUnits": 0.5,
      "snapshotDate": "2026-10-26T03:00:00Z",
      "glucoseDate": "2026-10-26T02:58:00Z",
      "pumpDataDate": "2026-10-26T02:57:00Z"
    }
  }
}
```

## Commands

The watch writes a binary property list to the command characteristic. Dates are plist dates. Integers are integers. Do not send a glucose target, a symbol, or an insulin-needs factor. Those keys are rejected so a watch cannot believe it set a range Loop did not store.

| Key | Type | Required | Meaning |
|---|---|---|---|
| `v` | Int | yes | Command schema version. `1`. A missing `v` is `malformed`. Any other value is `unsupportedVersion`. |
| `cmd` | String | yes | One of the names below. |
| `requestId` | String | yes | UUID, `UUID.uuidString`. Case-insensitive. The dedupe key. |
| `timestamp` | Date | yes | When the watch created the command. Plist date. Freshness only. Not the override start. |
| `presetId` | String | `preset.start` only | UUID of a preset in the latest `act.presets` list. |
| `durationSeconds` | Double | no | Used only on `preMeal.start` and `preset.start`. Ignored on stop. |

| `cmd` | Effect |
|---|---|
| `preMeal.start` | Turn on Pre-Meal using the target stored in Loop settings. Duration is `durationSeconds` when present, otherwise 1 hour. |
| `preMeal.stop` | Clear Pre-Meal only. Ok when Pre-Meal is already off. Does not clear a workout preset. |
| `preset.start` | Start that named preset with `TemporaryScheduleOverridePreset.createOverride(enactTrigger: .local)`. Duration is `durationSeconds` when present, otherwise the duration stored on the preset, including indefinite. |
| `preset.stop` | Clear the schedule override only (`clearOverride()`). `presetId` is ignored. Ok when nothing is running. Does not clear Pre-Meal. |

Pre-Meal and a schedule override may both be active. Loop keeps using the pre-meal target until the pre-meal override's scheduled end. Starting one does not cancel the other.

The override's start date is the phone's clock at the moment Loop applies the command. `timestamp` is not copied onto the override.

`durationSeconds` must be finite and greater than 0, and at most `act.limits.maxOverrideDurationSeconds` (24 hours). `0` is invalid. It does not mean indefinite. Indefinite is only available by omitting `durationSeconds` on `preset.start` when that preset is stored as indefinite. A stored finite duration longer than 24 hours is rejected instead of started. This is the same cap as `LoopConstants.maxOverrideDurationTime`. The phone status screen's APIs are the ones that run: `enablePreMealOverride(at:for:)`, `clearOverride(matching: .preMeal)`, `createOverride(enactTrigger: .local)`, and `clearOverride()`.

These names are recognized and rejected with `unsupported`. They do not change settings: `carbs`, `carbs.entry`, `carbs.start`, `bolus`, `bolus.enact`, `bolus.start`, `recommend`. Any other string is `unknownCommand`.

### Freshness and duplicates

Loop rejects a command when `timestamp` is more than 2 minutes older than the phone clock (`stale`), or more than 5 seconds ahead of it (`future`). A timestamp exactly 2 minutes old, or exactly 5 seconds ahead, is accepted. The 5 seconds is clock skew so a watch that runs slightly fast still works.

`requestId` is remembered for 24 hours, including across a relaunch. The window starts at the first time that id is processed and is not extended when the same id is written again. A duplicate returns the original ack and does not change settings. A command without a parseable `requestId` is `malformed` and is not remembered.

### Ack

Loop notifies the ack on the context characteristic, using the same chunk framing as a snapshot. The ack is its own plist. It is not a key inside the snapshot. A message with `ack` is a result. A message with `ctx` is a snapshot. After the ack has been queued, Loop pushes a fresh snapshot so the watch can read the new override state. Trust the snapshot for what is running. Trust the ack for what happened to this `requestId`.

If no watch is subscribed, the command is still processed and the ack is logged as not sent. Loop does not retry it later. The next subscribe sends a snapshot only.

| Key | Type | Required | Meaning |
|---|---|---|---|
| `v` | Int | yes | Envelope version. `1`, same number as a snapshot envelope. |
| `ack` | Dictionary | yes | The result. |
| `ack.requestId` | String | when the write contained one | The command's `requestId`. Omitted when the body was not a dictionary or had no UUID. |
| `ack.status` | String | yes | `ok`, `rejected`, or `error`. |
| `ack.reason` | String | on `rejected` and `error`, and on test-mode `ok` | See the table below. Omitted on a normal `ok`. |

`rejected` means Loop did not change settings. `error` means the command passed validation and then could not be applied (the preset or pre-meal target disappeared). That `requestId` is stored as `error`, so a replay does not try again. A new attempt needs a new `requestId`. `ok` means the override was applied, except when `reason` is `testMode`.

| `reason` | `status` | When |
|---|---|---|
| `testMode` | `ok` | No-dose test mode is on. Validation passed. Settings were not changed. |
| `stale` | `rejected` | `timestamp` is more than 2 minutes behind the phone. |
| `future` | `rejected` | `timestamp` is more than 5 seconds ahead of the phone. |
| `malformed` | `rejected` | Not a dictionary, missing `v`, `cmd`, `requestId`, or `timestamp`, or a present id is not a UUID. |
| `unknownCommand` | `rejected` | `cmd` is not one of the four override commands and not an explicitly unsupported carb/bolus name. |
| `unsupported` | `rejected` | Carb, bolus, or recommend. Capability for that action is false. |
| `unsupportedVersion` | `rejected` | `v` is present and is not `1`. |
| `missingPreset` | `rejected` | `preset.start` without `presetId`. |
| `unknownPreset` | `rejected` | `presetId` is a UUID and it is not in `LoopSettings.overridePresets`. |
| `preMealUnavailable` | `rejected` | `preMeal.start` and no pre-meal target is stored. |
| `durationInvalid` | `rejected` | `durationSeconds` is missing a usable number, is not finite, or is not greater than 0. Also a stored preset duration that is not positive. |
| `durationTooLong` | `rejected` | Finite duration is greater than 24 hours. |
| `customTarget` | `rejected` | The plist contains `targetLowerMgdl`, `targetUpperMgdl`, `targetRange`, `target`, `insulinNeedsScaleFactor`, or `symbol`. |
| `internal` | `error` | Validation succeeded and applying it through Loop's settings did not. |

Every accepted write is logged in Loop's diagnostic log under the `PixelWatchDataManager` category, with the command name, request id, status, reason, duplicate flag, and test-mode flag. Structural ATT failures are logged too. They have no ack.

### No-dose test mode

Boolean UserDefaults key `com.loopkit.Loop.PixelWatchCommandTestMode`. There is no settings screen for it. When the key is true, Loop still checks the command and still sends an ack, but a command that would have been `ok` is `ok` with reason `testMode` and Loop does not call the override APIs. Rejections are still rejections. The key is read on every command. Default is false.

Request ids are stored as JSON under `com.loopkit.Loop.PixelWatchCommandReceipts` for the 24 hour dedupe window.

### Example command

`preMeal.start` for the default hour, as a logical plist. On the wire, `timestamp` is a binary-plist date.

```json
{
  "v": 1,
  "cmd": "preMeal.start",
  "requestId": "8B1E6C2A-4D5F-4A1B-9C3E-0F7A6B5C4D3E",
  "timestamp": "2026-10-26T03:00:00Z"
}
```

Ack, then the watch should expect a snapshot with `preMeal.active` true:

```json
{
  "v": 1,
  "ack": {
    "requestId": "8B1E6C2A-4D5F-4A1B-9C3E-0F7A6B5C4D3E",
    "status": "ok"
  }
}
```

`preset.start` for a saved preset, keeping that preset's own duration:

```json
{
  "v": 1,
  "cmd": "preset.start",
  "requestId": "91C04E77-2B18-4F0A-8D55-6A0E1F2B3C4D",
  "timestamp": "2026-10-26T03:00:01Z",
  "presetId": "2F1C0A7E-6B4D-4E2A-9C11-8A0B1C2D3E4F"
}
```

## What this payload does not do

- No carb entry and no bolus. `cap.carbs` and `cap.bolus` stay false, and those command names are rejected.
- The watch never sends a custom glucose target or an insulin-needs factor. Presets are only presets that already exist on the phone.
- Nothing on this path calls `enactBolus` or `addCarbEntry`.
- The watch must not compute a dose from the snapshot. `recommendedUnits` / `rbo` is Loop's number.
- Loop does not retry a write, an ack, or an override.
