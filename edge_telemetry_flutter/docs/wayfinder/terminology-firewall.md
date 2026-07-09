# Flutter public-API terminology firewall (v2)

Resolves [#12](https://github.com/NCG-Africa/edge_telemetry_flutter/issues/12). Adopts the family
terminology firewall (canon: the Ionic SDK's `docs/terminology.md`) for `edge_telemetry_flutter`,
reconciled against this map's hard constraint — **Dart public API stays backward-compatible
(deprecate, don't remove)**.

## The landing (one line)

Backward-compat wins on every *existing* public symbol. So the firewall is **not** a rename pass —
it's a **forward-looking rule** governing three things only: **(1) docs/README/CHANGELOG/marketing
language, (2) any net-new public symbol this refactor introduces, (3) error-message text.** Existing
symbols that carry banned terms are grandfathered.

Applies to public surface: Dart public API names, docs, READMEs, error messages, changelogs. Does
**NOT** apply to `src/` internals, private members, comments, or the JSON payload's `eventName`/attr
keys (those are the internal wire vocabulary — governed by the eventName mapping, not this firewall).

## Banned terms — never in NEW public surface (family canon, adopted verbatim)

| Banned term | Use instead |
|---|---|
| `span` / `trace` / `tracing` | `event` |
| `tracer` / `SpanProcessor` / `SpanExporter` / OTel class names | (hide entirely) |
| `instrumentation` / `instrument` (verb) | `capture`, `record`, `monitor` |
| `telemetry` | `performance data`, `events` |
| `metric` / `metrics` (in API names) | `performance data`, or a plain verb (`record…`) |
| `OTLP` / `OpenTelemetry` | (never mentioned) |
| `emit` (data context) | `record`, `capture`, `send` |
| `sampling` | `capture rate` (config key `sampleRate` is the sanctioned exception) |
| `collector` | `your backend` |
| `pipeline` / `context propagation` | (internal — never mentioned) |
| `batch` / `batching` / `flush` (prose) | `sends` (config keys `batchSize`/`flushIntervalMs` are sanctioned exceptions) |
| `resource attributes` | `device info`, `app info` |

No Flutter-specific additions to the banned list.

## Grandfathered — EXISTING public symbols kept despite banned terms

Backward-compat overrides the firewall for shipped surface. These stay, unrenamed:

| Symbol | Banned term | Verdict | Why |
|---|---|---|---|
| `EdgeTelemetry` (class) | `telemetry` | **Keep** | Renaming breaks every consumer's import + call site. Diverges from family `EdgeRum`; noted, not fixed. |
| `trackMetric(name, value)` | `metric` | **Keep** | Renaming churns every consumer recording custom values, for a cosmetic win. |
| `useJsonFormat:` param | (OTel-era) | **Exempt** | Deprecated no-op, removed v3. Renaming death-row symbols is pointless churn. |
| `withSpan` | `span` | **Exempt** | Deprecated passthrough, removed v3. |
| `withNetworkSpan` | `span` | **Exempt** | Deprecated passthrough, removed v3. |

The 3 exempt no-ops are the OTel-era survivors ([#8](https://github.com/NCG-Africa/edge_telemetry_flutter/issues/8)/[#11](https://github.com/NCG-Africa/edge_telemetry_flutter/issues/11)); they die in v3, not renamed.

## Approved Dart public vocabulary

Existing symbols that already pass the firewall (no banned terms — keep as-is; naming may diverge
from family word-for-word but that's cosmetic, not a violation):

| Symbol | Firewall status | Family equivalent (for reference) |
|---|---|---|
| `initialize(...)` | clean | `init` |
| `trackEvent(name, {attributes})` | clean (`track`+`event` both approved) | `track` |
| `trackError(error, {stackTrace, attributes})` | clean | `captureError` |
| `addBreadcrumb(...)` + typed breadcrumb helpers | clean | — |
| `identify(...)` | clean | `identify` |
| `navigationObserver` | clean | — |
| `dispose()` | clean | `disable` |
| `instance` / `isInitialized` / `config` | clean | — |

Net-new public symbols this refactor introduces (from [#9](https://github.com/NCG-Africa/edge_telemetry_flutter/issues/9)/[#10](https://github.com/NCG-Africa/edge_telemetry_flutter/issues/10)) — these **must** pass the
firewall since they're new surface. All clean as proposed:

| New symbol | Status |
|---|---|
| `shutdown()` | clean (family uses `disable`; `shutdown` is not banned — keep) |
| `addBreadcrumb()` | clean |
| `maxQueueSize` (config) | clean (family config key) |
| `sampleRate` (config) | clean — **use `sampleRate`, not `sessionSampleRate`**; `sampleRate` is the sanctioned config key, and `sampling`-in-prose stays banned |

**Forward flag (for spec assembly, not decided here):** existing config keys `batchTimeout` /
`eventBatchSize` / `maxBatchSize` diverge from the family's sanctioned `flushIntervalMs` / `batchSize`.
That's a config-key-shape question (config API alignment), not a firewall violation — flagged for the
final spec, not renamed by this ticket.

## Enforcement

**Doc convention only** for this effort. The spec carries the approved-vocab + banned-term tables
above; reviewers enforce by eye — same as how the Ionic SDK ships its `docs/terminology.md`. **No
lint/CI public-API check** built: this is a planning effort producing a spec, and an automated
API-surface gate is execution-phase work (build it later if drift becomes a real problem, not
speculatively).
