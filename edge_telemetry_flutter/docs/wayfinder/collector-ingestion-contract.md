# Collector Ingestion Contract — what the Flutter SDK actually POSTs to

> Source: code audit 2026-07-09 of `NCG-Africa/EdgeTelemetryCollector` (Python/FastAPI, commit `a39a0b1`) + `NCG-Africa/EdgeTelemetryProcessor`.
> Resolves ticket #2. Companion to [`backend-contract.md`](./backend-contract.md) (which audited the **processor**) and [`family-alignment-reference.md`](./family-alignment-reference.md).
> **Key correction to backend-contract.md §5.1: the envelope-`type` conflict is a non-issue — see §4 below.**

## 1. Topology — the SDK talks to the Collector, not the processor

```
Flutter SDK ──HTTP POST /telemetry──▶ Collector (FastAPI) ──wraps {"data": body}──▶ Kafka "telemetry-upsert" ──▶ Processor ──▶ Postgres
             X-API-Key: <key>          auth + device.id gate + validate
                                       inject tenant_id + geo
```

The Collector is a **near-passthrough**: it authenticates, does light structural validation, injects `tenant_id`+`geo`, wraps the whole SDK body under a `data` key, and forwards to Kafka **verbatim**. It never rewrites event/envelope contents.

## 2. Request contract the Flutter SDK must satisfy

| Concern | Requirement | Source |
|---|---|---|
| **Path** | `POST /telemetry` on the collector. ⚠️ SDK/reference docs say `/collector/telemetry` — no prefix exists in the app (`main.py` mounts router at root). A gateway/ingress must be rewriting `/collector/*`→`/telemetry`. **Confirm the real public URL.** | `routes.py`, `main.py` |
| **Auth** | Default `AUTH_MODE=api_key` → header **`X-API-Key`**. Missing → 401. Format is `prefix_keyid_secret` (≥3 `_`-separated parts, e.g. `edgekey_abc123_xyz789`); validated by DB lookup on `prefix_keyid` + SHA-256 secret compare. (jwt mode swaps to `Authorization: Bearer`.) | `dependencies.py`, `auth_service.py`, `settings.py:67` |
| **`device.id`** | **REQUIRED** — must appear *somewhere* in the payload: root `device_id`, nested `device.id` object, flat `"device.id"` key, or inside `attributes` (recursive search, depth ≤10). Absent → **400** before Kafka. | `routes.py` |
| **`events`** | Non-empty array, length ≤ `MAX_BATCH_SIZE` (**1000**). Empty/missing → 400. | `payload_validator.py`, `settings.py:92` |
| **Per-event `type`** | Each event must have a `type` field (present). Value only restricted to `event/metric/log/span` **if `STRICT_SCHEMA_VALIDATION=true` — default is `false`**, so any value passes today. | `payload_validator.py`, `settings.py:94` |
| **`attributes`** | If present, must be an object. Otherwise arbitrary (`extra="allow"`). | `payload_validator.py`, `models.py` |
| **Size** | Whole payload ≤ 5 MB; per-event ≤ `MAX_EVENT_SIZE_BYTES`. | `settings.py:91` |
| **Top-level envelope `type`** | Collector **does not read or validate it at all.** (Only `events` presence is checked.) | `payload_validator.py` |

**Collector-injected (SDK must NOT send):** `tenant_id` (from the API key), `geo` (from client IP, `GEO_ENABLED=true` default), and the Kafka `{"timestamp", "data"}` wrapper.

## 3. What it ingests today

Everything. The collector is content-agnostic beyond §2. Flutter's current divergent shape (`type:"batch"`, `type:"error"` items, no `X-API-Key`) fails **only** on the missing `X-API-Key` (401) — the envelope/eventName divergences pass the collector untouched and land in Kafka. The processor is where eventName-specific storage happens (see `backend-contract.md` §3).

## 4. ✅ RESOLVED — the `telemetry_batch` vs `batch` "conflict" is cosmetic

`backend-contract.md` §5.1 flagged that the processor expects `type:"batch"` while the family canon says `type:"telemetry_batch"`. **Audit result: neither the Collector nor the Processor branches on the value.**

- Collector: never inspects top-level `type`.
- Processor: `TelemetryBatch.type` is `Field(...)` — **required to be present and a string, but its value is never compared or switched on** anywhere in the pipeline (`grep` for `"batch"`/`telemetry_batch` across `app/` → zero matches). It's read into the model and ignored.

**Decision:** Flutter v2 should emit `type:"telemetry_batch"` (aligns to canon, costs nothing). The only hard requirement is that some non-empty string `type` is present at the envelope root. No Collector rewrite exists or is needed. Conflict #1 is closed; conflicts #2 (attr key style) and #3 (crash shape) remain open for #4/#5 — those are processor-storage concerns, unaffected by the collector.

## 5. Adding NEW datapoints (the glossary mandate)

**No schema/registration step exists.** New eventNames and attributes flow through both hops freely (`extra="allow"`, strict validation off). BUT persistence is gated at the **processor**:

- **New attributes on existing events** → stored only if a processor extractor reads that key; unknown keys are silently dropped (except `user.profile.update`, which JSON-dumps arbitrary `user.*`).
- **New eventNames** (`page_load`, `app_lifecycle`, `user.interaction`, `custom_event`, `network_change`) → land in the generic `rum_performance_events` fallback only; no dedicated table/columns until the backend adds a handler.

So the glossary can *specify* new datapoints and they'll reach the backend, but querying them as first-class data requires **backend accommodation** (extractor + table changes). This is backend-team territory, not Flutter-side.

## 6. Questions for the backend team (flag for review)

1. **Public URL / path** — is `/collector/telemetry` gateway-rewritten to the collector's `/telemetry`? Confirm the exact ingest URL Flutter must use per environment.
2. **API key** — confirm the provisioned key string/prefix for the Flutter app (code shows `prefix_keyid_secret`, e.g. `edgekey_*`; reference doc said `edge_*`) and which tenant/app it maps to. Who issues it.
3. **AUTH_MODE in prod** — `api_key` (→ `X-API-Key`) or `jwt` (→ `Authorization: Bearer`)? Determines the SDK's auth header.
4. **New eventNames** — will the backend add dedicated handlers for `page_load` / `app_lifecycle` / `user.interaction` / `custom_event` / `network_change`, or should the Flutter glossary defer emitting them until then? (Affects glossary scope → feeds #4/#5.)
5. **Crash shape** — confirm `backend-contract.md` §5.3 still holds: processor wants an `app.crash` event with **unprefixed** keys (`message`/`stacktrace`/`cause`/`exception_type`/`is_fatal`), server computes `crash_hash`/`severity`/`breadcrumbs`. (→ #4)
