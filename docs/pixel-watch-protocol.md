# Pixel Watch status protocol

Read-only snapshot Loop publishes to a bonded Wear OS watch (Loop Wrist). The phone is the only dosing authority. This document is the contract for the watch parser. It describes the notify payload after the actions snapshot was added. It does not describe a command channel: this build has no write characteristic and does not enact boluses, carbs, or overrides.

## Transport

Unchanged from the first Pixel Watch build.

| | |
|---|---|
| Service | `354E12EF-6EA4-4255-B054-9D2A113E2C8D` |
| Characteristic | `219E7627-1F0C-4D0C-951F-FDC44514B868` |
| Properties | Notify, encryption required |
| Permissions | None. The value is not readable and not writable. |
| Direction | Phone to watch only |

A peer that is not bonded cannot subscribe. No characteristic on this service accepts writes.

### Framing

Each notification is:

| Offset | Size | Meaning |
|---|---|---|
| 0 | 1 | Flags. Bit 0 = first chunk of a message. Bit 1 = last chunk. |
| 1 | 1 | Sequence number within the message, starting at 0, wrapping as `UInt8`. |
| 2 | rest | Payload bytes |

The watch resets reassembly when it sees the first-chunk flag, appends payloads in sequence order, and parses when it sees the last-chunk flag. A gap in the sequence drops the message. A newer message may replace one that has not finished; the next first-chunk flag starts over.

The sequence byte gives a message at most 256 chunks. Chunk size is `max(18, maximumUpdateValueLength - 2)` bytes of payload. On a negotiated ATT MTU this is plenty. On a 20-byte link the budget is about 4.5 KB. If the full snapshot would exceed 256 chunks, the phone sends the same envelope without the preset list (`presetsTruncated` true, `presets` omitted). If that still does not fit, it sends the original envelope (`v`, `ctx`, `hg` only) and leaves `act` out. The watch treats a missing `act` as "no actions metadata" (every capability false), not as an empty preset list.

## Versioning

Three version numbers travel together. They are not interchangeable.

| Field | Current | What it versions |
|---|---|---|
| Envelope `v` | `1` | `ctx` and `hg`. Left at 1 so a watch that already reads those keys keeps working. |
| `ctx.v` | `5` | `WatchContext`, shared with the Apple Watch. This payload does not change it. |
| `act.v` | `1` | The actions snapshot described below. |

Rules for the watch:

- Ignore unknown keys at every level.
- Keep parsing `ctx` and `hg` for any envelope `v` that still includes them. Do not require `act`.
- Read `act` only when it is present. If `act.v` is newer than the watch understands, keep using the keys this document defines and ignore the rest.
- A missing capability key means false.

Bump `act.v` when an existing actions field changes meaning. Adding a key does not require a bump. Bump envelope `v` only when `ctx` or `hg` change meaning.

## Envelope

Binary property list. Top-level dictionary:

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
| `cap` | Dictionary | yes | Which commands this phone will accept. All `false` in this build. |
| `presets` | Array of dictionaries | no | Override presets, Loop's list order, at most 16. Omitted when dropped for size. |
| `presetsTruncated` | Bool | yes | `true` when `presets` is not the full list (capped, or omitted for size). |
| `override` | Dictionary | no | Unfinished schedule override. Omitted when none is running or scheduled. |
| `preMeal` | Dictionary | yes | Whether Pre-Meal is configured and whether it is on. |
| `limits` | Dictionary | yes | Bolus and carb limits Loop enforces. |
| `bolus` | Dictionary | yes | Recommended bolus and the input timestamps behind it. |

`presetsTruncated` false and `presets` present (possibly empty) means the watch has the complete list. `presetsTruncated` true and `presets` absent means the list was not sent; do not draw that as "no presets". `presetsTruncated` true and `presets` present means the first 16 presets were sent and Loop has more.

### `cap`

| Key | Type | This build | Command it will gate later |
|---|---|---|---|
| `preMeal` | Bool | `false` | Turn Pre-Meal on or off. |
| `workout` | Bool | `false` | Start a named preset, or cancel the schedule override. |
| `carbs` | Bool | `false` | Store a carb entry. |
| `bolus` | Bool | `false` | Enact a bolus. |

`false`, or a missing key, means the phone does not accept that command. This build publishes no write characteristic, so the watch must not write one. A later build that accepts a command has to set that boolean to `true` in the same release that accepts the write.

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
    "cap": { "preMeal": false, "workout": false, "carbs": false, "bolus": false },
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

## What this payload does not do

- No write characteristic, no command names, no request ids.
- Nothing in this path calls `enactBolus`, `addCarbEntry`, or `mutateSettings`.
- The watch must not compute a dose from these fields. `recommendedUnits` / `rbo` is Loop's number.
- Capabilities are all false until a later change both accepts a command and says so here.
