# v2.0.0 migration + deprecation strategy — #11

> Resolves [#11](https://github.com/NCG-Africa/edge_telemetry_flutter/issues/11). Consumes
> [`eventname-envelope-mapping.md`](./eventname-envelope-mapping.md) (#4 wire renames — internal),
> [`target-module-architecture.md`](./target-module-architecture.md) (#7 layout),
> the OTel-removal decision ([#8](https://github.com/NCG-Africa/edge_telemetry_flutter/issues/8) — the deprecation/break source),
> and surfaces the consumer build-break from [`native-crash-capture.md`](./native-crash-capture.md) (#10, iOS 14 floor).

The **wire** breaks at v2.0.0 (allowed). The **public Dart API** stays backward-compatible —
*refined rule*: **deprecate, don't remove — where "don't remove" means don't remove without a
shipped-and-elapsed deprecation cycle.** A symbol already deprecated in a released version *with a stated
removal target* is fair to remove.

## 0. Decisions (the forks that were open)

| Fork | Decision |
|---|---|
| **Governing principle** | "Deprecate, don't remove" = don't remove **without a shipped-and-elapsed deprecation cycle**. Pre-announced removals are honored. |
| **`runAppCallback`** | **Hard-removed in v2.** It was deprecated in ≤1.5.2 with an explicit "removed in v2.0.0" message (annotation + runtime print) — the cycle shipped and elapsed. |
| **Warning mechanism** | Behavior-changing deprecations get `@Deprecated` **+ a once-per-process runtime `print` guarded by `debugMode`**. Deprecation is a dev-time nudge, not a prod signal (unlike the always-on error logs). |
| **Version gating** | **Straight to v2**, no v1.x deprecation-bridge release. Deprecated no-ops removed in **v3.0.0** (not a v2.x minor — that would break semver). |
| **iOS 14 floor** | A **consumer build-break** (Podfile deployment target), surfaced by #10 — belongs in the migration guide even though it's not a Dart symbol. |

## 1. v2 deprecation set (kept as no-ops, removed in v3)

Each: `@Deprecated('... — removed in v3.0.0. <action>')` + one-time debug-gated runtime warn on first use.

| symbol | v2 behavior | `@Deprecated` message / action |
|---|---|---|
| `initialize(useJsonFormat:)` param | ignored (custom-JSON is the only path). If `false`, warn once. | "useJsonFormat is ignored; the SDK is custom-JSON only. Remove the argument. Removed in v3.0.0." |
| `withSpan(name, fn)` | runs `fn`, emits nothing (passthrough). | "withSpan no longer records a span; it just runs your function. Remove it or use trackEvent. Removed in v3.0.0." |
| `withNetworkSpan(...)` | runs `fn`, emits nothing (passthrough). | same shape as `withSpan`. |

- These are the symbols that **silently change behavior** but keep their signature — hence the runtime warn.
- No other config param is removed; `location`/`resolveLocation` were already never-sent (dropped internally, but if
  still accepted, treat as deprecated no-op under the same policy — confirm against the final #7 config surface).

## 2. v2 hard-break set (sanctioned source breaks — no shim)

Compile error on upgrade; documented in CHANGELOG with the fix. Four symbols:

| symbol | why sanctioned |
|---|---|
| `startSpan(...)` | returns the deleted OTel `Span` type — un-shimmable without keeping OTel types alive (#8). |
| `endSpan(...)` | consumes the deleted `Span` type (#8). |
| `activeScreenSpans` | exposes OTel span state that no longer exists (#8). |
| `runAppCallback` | pre-announced "removed in v2.0.0", cycle shipped and elapsed (this ticket). |

- `EdgeNavigationObserver`: consumer contract (`navigationObserver` getter + `MaterialApp` placement) **preserved**
  (#8). Its `registerScreenSpan` / `onSpanStart` / `onSpanEnd` ctor params are hard-removed under the same OTel-leak
  rationale as the span verbs.
- **Confirm nothing else forces a source break:** `initialize`, `instance`, `dispose`, `isInitialized`, `config`,
  `trackEvent`, `trackMetric`, `trackError` all keep signatures. Additive-only from #9/#10 (`addBreadcrumb()`,
  `maxQueueSize`, `shutdown()`) — no break. ✅ set is complete.

## 3. Migration guide structure (README + CHANGELOG)

Framing headline: **"The wire changed — your code mostly didn't."** Most consumers only bump the version.

1. **TL;DR upgrade block** — for the common case (no spans, default JSON): bump version, bump iOS Podfile to 14, done.
2. **Breaking changes** (the 4 hard-breaks) — before/after snippet each; all are OTel/span removals + `runAppCallback`.
   Most apps never called these.
3. **Deprecations** (§1) — "still compiles, now a no-op, remove before v3" table; note the debug-console warning.
4. **Consumer build-break** — **min iOS 14**: `platform :ios, '14.0'` in the Podfile + `IPHONEOS_DEPLOYMENT_TARGET`.
   Explain it's required by native crash capture (MetricKit, #10). Android floor unchanged.
5. **What you get** — native crash capture, offline reliability, family-aligned wire (mostly invisible to app code).
6. **CHANGELOG `## [2.0.0]`** — `### Breaking` (4 removals + iOS 14 + wire), `### Deprecated` (§1), `### Added`
   (#9/#10 additive API), `### Changed` (internal: OTel gone, custom-JSON only, 5s flush).

## 4. Version timeline

```
v1.5.x  (shipped)  runAppCallback already @Deprecated('removed in v2.0.0')
v2.0.0             deprecate no-ops: useJsonFormat:false, withSpan, withNetworkSpan   [-> v3]
                   HARD-REMOVE: startSpan, endSpan, activeScreenSpans, runAppCallback,
                                EdgeNavigationObserver span ctor params
                   wire break (envelope + eventNames, internal — host doesn't choose these)
                   consumer build-break: min iOS 14 (Podfile)
                   additive: addBreadcrumb(), maxQueueSize, shutdown()
v3.0.0             drop the §1 deprecated no-ops
```

No interim v1.6 bridge — "delete before you add"; keeping OTel alive one more release to pre-warn contradicts #8.

## 5. Rejected / not built

- **v1.6 deprecation-bridge release** — an extra release keeping OTel alive to give an annotations-only warning
  cycle; rejected (slower, contradicts #8's clean removal). The debug-gated runtime warn covers the "spans vanished"
  confusion without it.
- **Removing the no-ops in a v2.x minor** — breaks semver; removals wait for v3.0.0.
- **Always-on runtime deprecation warnings** — deprecation is a dev-time concern; prod log noise not warranted
  (contrast the intentionally always-on *error-report* logs).
- **Shimming the span verbs** — would require keeping OTel `Span` types in the tree; the whole point of #8 is deleting them.

## 6. Closes the terminology-firewall fog

With the deprecation/break set now fixed, the surviving public surface is fully knowable — the only OTel-era
symbols remaining are the three §1 deprecated no-ops (gone in v3). This unblocks the **terminology firewall**
fog item (adopt the family banned-terms list; the approved Dart vocab is now enumerable).
