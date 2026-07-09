# Identity Contract — IDs + platform values for Flutter v2

> Resolves ticket #6 (grilling, HITL — decided with the dev 2026-07-09).
> Companion to [`family-alignment-reference.md`](./family-alignment-reference.md) §3, [`collector-ingestion-contract.md`](./collector-ingestion-contract.md), [`before-inventory.md`](./before-inventory.md).
> Grounding: `EdgeTelemetryProcessor` stores `device.platform` (free-form `String(50)`) as the device grouping key and **does not read `sdk.platform` at all** — so any `sdk.platform` change is a dashboard/analytics concern, not an ingest concern.

## Decisions

### 1. ID `{platform}` token = real OS, runtime-resolved
Format stays `{prefix}_{epochMs}_{16hex}_{platform}` for `device.id` and `session.id`. On Flutter, `{platform}` = the actual OS (`ios` / `android`) via `Platform.operatingSystem` — **not** a literal `flutter`. A Flutter-iOS device id is byte-shape-identical to a native-iOS one, so cross-platform device grouping (keyed on `device.platform`) works with zero backend change. The "built with Flutter" distinction lives only in `sdk.platform` (below). *(This is already what the current SDK does — no change to the token.)*

### 2. `sdk.platform` = `flutter-ios` / `flutter-android` (composed)
The `sdk.platform` attribute encodes SDK **and** OS in one value: `flutter-ios` or `flutter-android`. Denormalized (redundant with `device.platform`) but lets a dashboard split Flutter-iOS vs Flutter-Android from a single attribute. **Two new values the backend dashboards/analytics must accommodate** (ingest processor is unaffected — it ignores `sdk.platform`). → backend-team request.

### 3. `device.id` persistence = `flutter_secure_storage` (cross-install on iOS)
Move device.id persistence off `shared_preferences` onto **`flutter_secure_storage`** (new dependency):
- **iOS:** Keychain survives uninstall → reinstall keeps the **same** device.id (cross-install continuity).
- **Android:** EncryptedSharedPreferences is still wiped on uninstall → reinstall = **new** device.id.
- **Asymmetry across platforms is accepted**, not a bug to fix. Document it. Still "persisted, not rotated" within a platform's normal lifecycle (launches, updates).

### 4. `user.id` = SDK-owned anonymous, stable across `identify()`
SDK generates an anonymous `user_{epochMs}_{16hex}` on first run and persists it. `identify()` / `setUserProfile()` **attaches** profile data (name/email/phone/custom → `user.*`) but **never changes the `user.id` value**. Anonymous and identified events stitch to one continuous user timeline. Parity with iOS/Android/RN; backend backfills profile opportunistically (see `backend-contract.md` §3, `user.profile.update`).

### 5. Entropy = 16 hex via `Random.secure()`
Widen the random segment from today's **8 lowercase-alnum chars (~41 bits, non-crypto `dart:math Random`)** to **16 hex chars (64 bits) from `Random.secure()`** (CSPRNG). Matches the family exactly. The id **string format breaks** — acceptable under the v2.0.0 wire break — but old persisted ids stay valid: **the format validator must accept both the 8-alnum and 16-hex widths during migration** so a device that upgrades in place isn't forced to regenerate its id.

## Resulting identity attributes on the wire (Flutter v2)
```
device.id       = device_{epochMs}_{16hex}_{ios|android}   (secure-storage persisted)
session.id      = session_{epochMs}_{16hex}_{ios|android}  (fresh per session; 30-min idle → new)
user.id         = user_{epochMs}_{16hex}                   (anon, stable across identify())
device.platform = "ios" | "android"                        (real OS; device grouping key)
sdk.platform    = "flutter-ios" | "flutter-android"        (NEW values → dashboards)
```
`device.id` must appear somewhere in every batch or the Collector 400s (see `collector-ingestion-contract.md` §2).

## Backend-team requests raised
1. **`sdk.platform` new values** — dashboards/analytics must learn `flutter-ios` / `flutter-android` (ingest already tolerant). Confirm any platform-filter UI is updated.
2. **Cross-install device.id (iOS)** — confirm the backend has no assumption that a reinstall yields a new device row; on Flutter-iOS the same device.id will reappear post-reinstall.
