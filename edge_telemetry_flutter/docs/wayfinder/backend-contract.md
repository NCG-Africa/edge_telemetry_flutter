# Backend Contract — EdgeTelemetryProcessor (what the SDK data must match)

> Source: code audit 2026-07-09 of `mktowett/EdgeTelemetryProcessor` (Python, SQLAlchemy + Kafka).
> Scope: what the processor STORES and the payload SHAPE it consumes. `location`, `tenant_id`, `geo` are added by the **Collector Service** (upstream), NOT the mobile SDK — excluded here.
> Companion to [`family-alignment-reference.md`](./family-alignment-reference.md). **Where they conflict, this doc reflects the running backend; see §5.**

## 1. Topology — SDK does NOT talk to this backend directly

```
Flutter SDK ──HTTP POST──▶ Collector Service ──publishes──▶ Kafka topic ──consumes──▶ EdgeTelemetryProcessor ──▶ Postgres
                           (auth: X-API-Key,                (validated batch,
                            adds location/tenant_id/geo)     type:"batch")
```
- The processor is a **Kafka consumer** (`app/infrastructure/kafka_consumer.py`), no REST ingest endpoint, no SDK-facing auth.
- The SDK's HTTP target + `X-API-Key` (reference doc §1) is the **Collector**, not this processor. What auth/path the Collector expects is a **separate open question** (belongs to ticket #2).

## 2. Batch envelope the processor parses (`app/domain/telemetry.py`)

Accepts either `{...batch...}` at root OR wrapped as `{"data": {...batch...}}` (`telemetry_service.py:80`).

| key | req | notes |
|---|---|---|
| `type` | ✅ | discriminator = **`"batch"`** (see §5.1) |
| `events` | ✅ | array of items |
| `timestamp` | ✅ | ISO-8601 |
| `batch_size` | ➖ | defaults to `len(events)` |
| `location` / `tenant_id` / `geo` | ➖ | Collector-injected — **not SDK's job** |

**Event item:** `{ type: "event"|"metric", eventName?, metricName?, value?(metric), timestamp, attributes:{flat} }`.

## 3. Recognized `eventName` → table (the actual persisted allowlist)

The processor branches on eventName (`event_processor.py`). **Only these 7 have dedicated storage; everything else falls through to a generic performance-event row.**

| eventName | writes to | attribute keys read |
|---|---|---|
| `http.request` | rum_http_requests | `http.url/method/status_code/duration_ms/timestamp/success` |
| `navigation` | rum_navigation_events | `navigation.from_screen/to_screen/method/route_type/has_arguments/timestamp` |
| `screen.duration` | rum_screen_durations | `screen.name/duration_ms/exit_method/timestamp` |
| `app.crash` | rum_crash_events | `message`, `stacktrace`, `exception_type`, `error_context`, `product_id`, `cause`, `error_code`, `user_action`, `is_fatal` (⚠️ **unprefixed**, not `crash.*`) |
| `session.started` | (no-op; session auto-created) | — |
| `session.finalized` | updates rum_sessions + summary | `session.duration_ms/start_time` |
| `user.profile.update` | rum_users | `user.id/name/email/phone/profile_version/profile_updated_at` + arbitrary `user.*`→JSON |
| **`type:"metric"`** (any metricName) | rum_performance_metrics | `metricName`, `value`, `metric.unit`, frame/memory internals |
| **any other eventName** | rum_performance_events (fallback) | `memory.*`, `frame.*` |

**Not specially handled** (fall through to generic perf-event, i.e. mostly dropped detail): `page_load`, `app_lifecycle`, `user.interaction`, `custom_event`, `network_change`, `session.started` detail. → gap between the "family canon allowlist" and what THIS backend actually stores.

## 4. Common identity attributes every event must carry

`app.name`, `app.version`, `app.build_number`, `app.package_name` (or `app.package`) — **required** (used to resolve app/session FKs).
`device.id` (**required**, new strategy), `device.platform` (required), + optional `device.platform_version/model/manufacturer/brand/android_sdk/android_release/fingerprint/hardware/product`.
`user.id` (**required**), optional `user.name/email/phone` (opportunistic backfill).
`session.id` (**required**), `session.start_time`|`session.startTime` (required), optional `session.duration_ms/event_count/metric_count/screen_count/visited_screens/is_first_session/total_sessions`.
`network.type` (optional, stored on session).

Missing **required** identity attrs → event skipped (fail-soft, per-event savepoint, batch never rejected). Missing optional → NULL.

## 5. ⚠️ Conflicts with `family-alignment-reference.md` — resolve before spec

1. **Envelope `type`:** processor parses **`"batch"`**; reference doc §1 calls `"telemetry_batch"` the canon and `"batch"` the laggard form. Either the Collector rewrites `telemetry_batch`→`batch`, or the "canon" is wrong for this backend. **Must confirm what the Collector accepts/emits.** (→ #2)
2. **Attribute key style:** processor prefers **dotless** for frame/memory metric internals (`frame_build_duration`, `memory_type`) — dotted (`frame.*`) is legacy-compat. But identity/http/nav/screen/session/user keys ARE dotted. So the wire is *mixed*, not uniformly dotted as reference doc §1 implies. (→ #4/#5)
3. **Crash shape:** processor wants an **`app.crash` event** with **unprefixed** keys (`message`, `stacktrace`, `cause`, `exception_type`, `is_fatal`) — NOT `crash.*`, and NOT the current Flutter `type:"error"` item. `severity_level`, `crash_hash`, `breadcrumbs` are **computed server-side**. (→ #4)

Also: the processor stores no dedicated tables for `page_load`, `app_lifecycle`, `user.interaction`, `custom_event`, `network_change` — so aligning Flutter to emit those (per canon) yields data that lands only in the generic perf-event fallback until the backend adds handlers. **Backend accommodation request territory.** (→ #2, out-of-scope note: backend changes)
