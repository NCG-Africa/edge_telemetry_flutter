# Migrating to v3.0.0

*Guide dated 2026-09-30. Companion to [`CHANGELOG.md`](CHANGELOG.md) `[3.0.0]`.*

**The wire changed *and* your code changed.**

v2's migration note led with "the wire changed — your code mostly didn't." This
one inverts it, because for v3 the honest headline is the other way round: the
compile breaks are few and mechanical, and the *data* breaks are the ones that
will surprise you.

No v2 event or metric name was renamed, and none was removed from the
allowlist. That makes v3 **additive by name** — and it is the only sense in
which v3 is additive. Additive by *value* and by *presence* is false seven
times. Calling the release wire-additive on the no-renames technicality would be
exactly the dishonesty the five honesty keys (`http.url_redacted`,
`memory.source`, `http.response_size_source`, `http.seam`, `traceparent.outcome`)
were minted to prevent, and a release note gets the same rule the wire gets.

What makes the change sellable is bag-first storage: every raw key is stored
whether or not a typed column exists for it yet, so a not-yet-promoted key is a
**backfill, not a loss**. The promise is:

> Your code changes once; your dashboards change too — and nothing you collected
> is lost.

---

## 1. The seven breaks that are not compile errors

Read this section before you read anything else. Each of these keeps its name
and changes what arrives under it, so nothing fails to build and every dashboard
built on it needs a second look.

### 1.1 Screen dwell stops arriving as its own event

`screen.duration` is no longer emitted (deprecated in place, removal in v4.0.0).
The same measurement now rides the `navigation` event as
`screen.previous_duration_ms` — one navigation, one item, instead of two.

**Do:** repoint dwell-time charts at the `screen.previous_duration_ms` attribute
of the `navigation` event. A chart still reading `screen.duration` goes empty,
not wrong.

### 1.2 URLs become paths

`http.url` defaults to **path-only and id-templated**: scheme, host, query and
numeric/uuid path segments are gone (`https://api.x.com/orders/8412?token=abc`
→ `/orders/{id}`). This is one of four deliberate meaning changes under an
unchanged column, and it carries an in-band flag: `http.url_redacted`.

**Do:** any dashboard grouping by full URL now groups by path template — usually
an improvement, always a different key space. There is **no `http.host`**, and no
other key carries the host either — per-host grouping is gone rather than moved.
Nor is there a service-identity key to fall back on: `serviceName` rides
`telemetry.initialized`, which is off-canon and hard-dropped by the allowlist, so
it has never reached the wire. If you call more than one backend and need them
apart, the path templates are what distinguishes them.

### 1.3 Memory becomes a different quantity

`memory_usage` re-bases from Dart's `currentRss` to the platform's own figure —
`phys_footprint` on iOS, total PSS on Android. v2's number was the wrong number
on **both** platforms and the two were not comparable with each other.
`memory.source` (`footprint` / `pss`) puts the break on the wire.

**Do:** treat pre-v3 and post-v3 memory as two series. Do not draw a trend line
across ship day. Also note the *cadence* is gone: memory now arrives twice per
session (open and `paused`), not every 10 seconds — see §5.

### 1.4 Lifecycle fires twice per round-trip, not six times

`app_lifecycle` emits `paused` and `resumed` only. `inactive`, `hidden` and
`detached` move to `Capture.lifecycleTransitions` (`diagnostic`, opt-in). The
framework synthesizes all three on every backgrounding round-trip, so v2 shipped
six items where the budget assumed two.

**Do:** if something counted lifecycle items as a proxy for anything, recount.
Restore the old volume with
`captureOverrides: {Capture.lifecycleTransitions: true}`.

### 1.5 `device.name` is gone on iOS

Removed, not tiered, not flagged: it is the only key in the static bag that can
carry a human's name, because the iOS default is "Marvin's iPhone".
`device.identifier_for_vendor` goes too — redundant rather than a privacy
concession, since `device.id` sits beside it and survives a reinstall.

**Do:** anything keyed on `device.name` loses its key. `device.model` is the
nearest replacement.

### 1.6 Route names stop being fabricated per visit

An unnamed route used to be named `screen_<Type>_<hashCode>`, which minted a
**fresh value on every visit** — so every screen-keyed dashboard carried
cardinality equal to total navigations across all users. It is now the route
type (`unnamed_MaterialPageRoute`). Visit identity is what the new `screen.id`
is for; a grouping key that never repeats groups nothing.

Parameterised names (`/orders/8412`) are **documented, not sanitized** — the SDK
cannot tell a segment you meant as a name from one you meant as an id, and
guessing would silently rename your screens. `screen.name`, `navigation.to` and
`navigation.from` now share `http.url`'s per-session distinct-value cap.

**Do:** name your routes. Historical unnamed-route rows will not join to the new
ones — there was never anything to join them on.

### 1.7 Crash volume goes from zero to real

**No consumer has received a crash since v2.0.0.** The immediate rail POSTed a
bare wire item with no `events` array, the collector answered 400, and the
payload parked in a cap-exempt file that was re-POSTed after every successful
batch for the life of the install. Externally this was indistinguishable from an
app that does not crash, which is why the bug survived a release.

**Do:** read §6 before ship day. This is the one break with an operational
consequence.

---

## 2. Errata register

*Dated 2026-09-30.* This register is deliberately separate from the break list.
*Removed in v3* is a change you act on. *Never worked in v2* is a belief you need
corrected about telemetry you have **already shipped and drawn conclusions
from**.

- **2026-09-30 — `enableErrorReporting` has had no effect since v2.0.0.** Error
  capture has been unconditional since that release. The parameter was **absent
  from `initialize()`** and the config field was **hardcoded to `true`** at the
  sole construction site. There was no `@Deprecated` annotation, no runtime
  warning, and no changelog line. A consumer who believed they had switched
  error reporting off was transmitting throughout.
- **2026-09-30 — `TelemetryConfig.hasAutomaticMonitoring` could never return
  `false` in v2.0.0.** It OR'd five flags, one of which was
  `enableErrorReporting` — always `true` per the entry above. The getter was a
  tautology, so any code branching on it took the true branch always. It now
  reports whether any capture is actually enabled.
- **2026-09-30 — `user.interaction` and `resource_timing` have never produced a
  row from this SDK.** Both sit on the wire allowlist for family conformance and
  neither has ever been emitted, in v2 or before. If a dashboard panel for
  either has been empty, it was empty for this reason and not because the signal
  was rare. Their v3 replacements are `ui.interaction` (now emitted
  automatically) and the `http.*` phase keys.
- **2026-09-30 — the declared Android and Dart/Flutter floors were below the
  real ones.** See §4: the package resolved onto projects that then failed to
  build.

---

## 3. The hard compile breaks

There are four, and each is a knob being handed over rather than taken away.

### 3.1 `enableCrashReporting` and `enableErrorReporting` — removed outright

This is the one sanctioned exception to deprecate-don't-remove, and it is
deliberate. `enableCrashReporting` **worked** in v2. Turning a working switch
into a silent no-op means a consumer who had deliberately suppressed crash
reporting begins transmitting on a `pub upgrade`. A `@Deprecated` lint is
scrollable and an init-time `print` is invisible to a CI-only consumer; only the
compiler is unignorable, and unignorable was the requirement.

Crash and error capture are unconditional in v3, and the `Capture` enum has no
member for either — an SDK reporting no crashes must never be indistinguishable
from one configured not to.

The right knob for each reason you might have set it:

| Your reason | The knob |
|---|---|
| **Privacy** | `app.crash` carries no arbitrary consumer attributes, and `redactAttribute` covers the half you supplied. Privacy here is a *content* problem, not an existence problem. |
| **Volume** | `tier: CollectionTier.essential`. Crash was never the cost: at under 1% of the item ceiling, it is not what your budget is spent on. |
| **"I don't want this feature"** | Then the dependency is wrong. This package is a crash reporter among other things; there is no configuration that makes it not one. |

### 3.2 `useJsonFormat` — removed, and this is the one un-cycled break

`initialize(useJsonFormat:)` and `TelemetryConfig.useJsonFormat` are gone. The
SDK has been custom-JSON only since v2.0.0, so the field was already a no-op.

**Stated plainly rather than hidden:** the `TelemetryConfig` field **never
carried a `@Deprecated` annotation**, so a consumer who constructed the class by
hand gets a compile error with no deprecation cycle behind it. That is a
violation of the cycle in §7 and it is named here instead of being left to the
compiler to explain. The facade parameter was annotated; the field was missed.

### 3.3 `batchTimeout` / `maxBatchSize` / `eventBatchSize` — removed

Shipped no-ops. Use `flushIntervalMs` and `batchSize`, which are the canon names
and are actually read.

### 3.4 `withSpan()` / `withNetworkSpan()` — removed

OTel-era no-ops that recorded nothing.

---

## 4. Platform floor corrections

Both of these raise a *declaration* to match a floor that was already being
enforced. Neither drops support that worked.

- **Android `minSdk` 19 → 21.** `shared_preferences_android` and
  `path_provider_android` both declare `minSdkVersion 21`, so the manifest
  merger raised every v2 build's effective floor to 21 while this package's
  `build.gradle` advertised 19. A consumer at 19 could not build; they can now
  read why from the constraint instead of from a merger error.
- **Dart `>=3.0.0` → `>=3.7.0`, Flutter `>=3.0.0` → `>=3.29.0`.**
  `device_info_plus` already demanded Dart 3.7 / Flutter 3.29. The understated
  constraint let pub resolve this package onto projects that then failed to
  build. Raising it stops advertising support that never existed.
- **No new iOS floor and no iOS build break.** iOS 14 (MetricKit) is unchanged
  from v2.

---

## 5. What replaces the deleted device-health time series

v2 sampled memory every 10 seconds and ran a 30-second system check —
**−58 items per session** once both are gone, which is most of what pays for
v3's new signals. The 10-second `memory_usage` sample, the 30-second
`performance.system_check`, the `performance.memory_pressure` threshold event and
`performance.monitor_initialized` are deleted at the source. Two of the three
names were being dropped by the allowlist on every device anyway.

Two signals replace them, and neither is a time series:

- **Memory at the two session bookends** — session open, and once on `paused`.
- **A five-key fault bundle on fatal crashes only** — `device.battery_level`,
  `device.battery_charging`, `device.power_save_mode`, `device.thermal_state`,
  `device.orientation`, read off the dying thread. Android only: MetricKit
  delivers next-launch, and this launch's device state is not that crash's
  state. `device.thermal_state` is a **normalised string**, never the platform
  ordinal — Android's `2` is MODERATE and iOS's is serious. An unavailable key
  is **omitted, never sentinelled**.

`long_task` keeps its name and its slot but **changes population**: v2 rows were
frames over 16.67 ms, v3 rows are frozen frames over 700 ms, and it is
`diagnostic`-only — so a default-config consumer now gets none.

`frame_render_time` is deprecated in place (removal v4.0.0) and no longer
emitted: a per-frame metric at 60–120 Hz became the windowed `frame.summary`
event. Any dashboard averaging it goes flat; read `frame.slow_frame_rate` and the
`frame.max_*` keys instead.

---

## 6. For whoever owns the pipeline: read this before ship day

**On the day v3 first runs, crashes accumulated undeliverable since v2.0.0
arrive in volume, backdated by weeks.**

Every crash since v2.0.0 was written to a cap-exempt file on device and never
accepted by the collector (§1.7). v3 re-wraps a payload stored bare by an
earlier version when it drains, so the whole backlog lands as soon as v3 runs
once per install — each row carrying **its original timestamp**.

This is an **entirely historical spike, not a live incident.** Concretely:

- Crash-rate alerting will fire. Suppress or widen it for the rollout window.
- The spike is spread across *past* dates, not today's, so a dashboard bucketing
  by event time will appear to rewrite history. That is the correct behaviour.
- Volume scales with install base times weeks of crashes, not with anything
  happening now.
- Fatal crashes ride the immediate rail as one-item batches, so they arrive
  without waiting for a batch to fill.

Distinguish the backlog from live crashes by comparing event timestamp to
ingestion time, or by `sdk.version`.

---

## 7. The deprecation cycle, written down

This is the rule every v3 deprecation followed, recorded here so the next one
has something to conform to. **Enforcement stays doc convention — there is no
lint gate**, deliberately: the gate would have to understand the wire canon, and
a gate nobody can read is worse than a rule everybody can.

A deprecation-in-place is four things:

1. **A `@Deprecated` annotation naming the removal version, on *every*
   declaration** — the field, the constructor parameter, *and* the `copyWith`
   parameter. "Every declaration" is the clause that catches a missed field, and
   §3.2 is what happens when it is not honoured.
2. **A shipped release** in which the name still works.
3. **A changelog line.** A deprecation nobody can find in `CHANGELOG.md` did not
   happen.
4. **A runtime warning wherever behaviour *changes* rather than disappears.** A
   name that stops being emitted needs no warning — the rows simply stop. A name
   whose meaning moves under you does.

Names are retained; emission stops or changes. **No v2 name is ever renamed**, and
no v2 name has its meaning changed under the same backend columns except where
the v2 meaning was *wrong* — four such carve-outs exist in v3, each recorded here
and none of them a precedent. **Two of the four carry an in-band flag**
(`http.url_redacted`, `memory.source`); the `http.duration_ms` re-base and the
`http.success` narrowing to 2xx carry none, because there is no honest per-row
value to put one on — the change is in what the number measures, not in whether
this row was treated specially.

**Every v3 deprecation names v4.0.0.** Currently deprecated in place:

| Name | Replacement |
|---|---|
| `screen.duration` (event) | `screen.previous_duration_ms` on `navigation` |
| `frame_render_time` (metric) | `frame.summary` event |
| `enableHttpMonitoring` | `captureOverrides: {Capture.http: false}` |
| `enableNavigationTracking` | `captureOverrides: {Capture.navigation: false}` |
| `enablePerformanceMonitoring` | `captureOverrides: {Capture.frames: false, Capture.health: false}` |
| `enableNetworkMonitoring` | `captureOverrides: {Capture.connectivity: false}` |
| `captureAccessibilityContext` | `captureOverrides: {Capture.accessibilityContext: true}` |

The five config booleans are still honoured as a fallback; `captureOverrides`
always wins.

**`user.interaction` and `resource_timing` are deliberately not on that table.**
CLAUDE.md lists them among the deprecated-in-place names, and that classification
is being corrected here: a deprecation-in-place stops or changes an *emission*,
and neither name has ever been emitted by this SDK (§2). There is nothing to
deprecate and no removal version to name — they are allowlist entries kept for
family conformance, because a canon name is never removed. They are errata, not
deprecations. `enableLocalReporting` is **not** deprecated — it gates a sink (the
on-device report store), not a capture, and never touches the wire.

---

## 8. The upgrade, in order

1. Raise your floors: Android `minSdkVersion 21`, Dart 3.7 / Flutter 3.29. iOS
   stays at 14.
2. `edge_telemetry_flutter: ^3.0.0`.
3. Build. Delete `enableCrashReporting` / `enableErrorReporting` /
   `useJsonFormat` / `batchTimeout` / `maxBatchSize` / `eventBatchSize` /
   `withSpan` / `withNetworkSpan` from your call sites.
4. If you were suppressing crash reporting, pick the knob from §3.1 that matches
   your actual reason.
5. Move any capture booleans to `captureOverrides` (optional — they still work
   until v4.0.0).
6. Optional and worth it: set `traceHostAllowlist` to link mobile taps to
   backend spans (**empty by default means dark — no `traceparent` header is
   injected anywhere**, because the header carries internal trace topology), and
   add `startTask` / `completeTask` / `failTask` around a multi-screen journey —
   the one category with no automatic source.
7. Fix the seven dashboards in §1.
8. Tell whoever owns the pipeline about §6 **before** you ship.

---

## 9. The backend-side companion

The family change request — the bag-first JSONB storage proposal that makes a
not-yet-promoted key a backfill rather than a loss — is tracked as
[#77](https://github.com/NCG-Africa/edge_telemetry_flutter/issues/77). It is the
backend-side companion to this guide and **not a code dependency of this
release**: because the raw key is always stored, a ship date here and a column
date there are independent.

---

## Migrating from 1.x

See [`README.md`](README.md#-migrating-from-1x-to-200) and
[`CHANGELOG.md`](CHANGELOG.md) under `[2.0.0]`. Upgrade to 2.0.0 first if you are
on 1.x; the two guides do not compose.
