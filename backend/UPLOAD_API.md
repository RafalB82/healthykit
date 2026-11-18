# HealthSync upload API

The iOS app posts JSON batches to the confirmed backend. Enter a base URL (without `/api/apple-health/sync`) in the app.

```http
POST /api/apple-health/sync
Authorization: Bearer <upload-token>
Content-Type: application/json
X-Device-Id: <stable-local-device-id>
X-App-Version: <app-version>
```

See the [example request and response fields](README.md#api) for the self-hosted backend. The app sends schema version 2; the backend also accepts version 1. Use HTTPS in production.

## Retries and deletions

Each batch has an `export_id` that stays the same on retries. A workspace stores at most one batch per export ID. Raw HealthKit records use IDs of the form `healthkit:{sample_uuid}`; daily summaries use separate deterministic IDs. Record IDs are scoped to the workspace and device.

Incremental uploads can also include `deletions`, an array of objects with a record `id` and a `kind` of `metric` or `workout`. Apply deletions only in the authenticated workspace and for the originating device. Retrying a deletion of an already-absent record is safe.

## Workout records

Activity names use HealthKit's lowerCamelCase names, such as `elliptical`, `rowing`, and `highIntensityIntervalTraining`. An explicit Other workout is `other`; unrecognized activity types use `hk_<rawValue>`. The numeric type is retained as a string in `metadata.hk_workout_activity_type`.

These fields are sent when available from HealthKit and allowed by read access:

| Field | Meaning |
| --- | --- |
| `active_energy_kcal` | Active energy from workout statistics or the legacy workout energy value. |
| `total_energy_kcal` | Active plus basal energy. Omitted when either component is unavailable. |
| `distance_meters` | Recorded workout distance, otherwise the sum of associated distance statistics, including rowing on supported iOS versions. |
| `metadata.average_heart_rate_bpm` | Average associated heart rate. |
| `metadata.max_heart_rate_bpm` | Maximum associated heart rate. |
| `metadata.average_mets` | Average METs from workout metadata or associated physical-effort statistics, in kcal/(kg·hour). |
| `metadata.workout_effort_score` | Latest related effort rating, falling back to associated workout statistics on iOS 18+. |
| `metadata.estimated_workout_effort_score` | Latest related estimated effort rating, with the same fallback on iOS 18+. |

Metadata values are strings, including numeric summaries. Source metadata is retained. Missing values are omitted, not filled with zero. Earlier app builds could report active energy as `total_energy_kcal`; use `active_energy_kcal` for active calories. Already queued payloads keep their saved values.

- Selecting Workouts requests read access to supporting types. To request permissions again, open **Settings → Apple Health Access**. Missing optional effort access does not prevent workout export. Raw heart-rate samples remain separate from workout summaries.
- Summaries are snapshots from incremental reads, recent rereads, and backfill. Daily maintenance rereads today and the previous three local calendar days. Manually backfill the affected dates to pick up older edits.
- See Apple's [workout statistics API](https://developer.apple.com/documentation/healthkit/hkworkout/statistics(for:)) and [related effort predicate](https://developer.apple.com/documentation/healthkit/hkquery/predicateforworkouteffortsamplesrelated(workout:activity:)).
