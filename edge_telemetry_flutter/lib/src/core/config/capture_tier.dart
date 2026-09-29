// lib/src/core/config/capture_tier.dart
//
// The v3 collection model: a tier dial and a capture override map. Two fields,
// not a pile of booleans — one map handles both directions, so there is no
// enable/disable pair to keep consistent and no const set to export and version.

/// Collection level — an **on/off plus a shed rank**, never a third sampling
/// axis. Per-tier sample rates would make the once-per-session roll incoherent
/// (a session sampled-in for screens and sampled-out for HTTP reconciles with
/// nothing). Tiers decide *what is collected at all*; `sampleRate` decides how
/// often, once, for the whole session.
enum CollectionTier {
  /// Never shed, never sampled, no off-switch: `app.crash` (fatal and
  /// non-fatal), `session.started` / `session.finalized`, `user.profile.update`
  /// — v2's shipped sampling-bypass set, verbatim. The set that must survive
  /// sampling, the set that must survive shedding and the set that must survive
  /// the consumer are one set, for one reason.
  essential,

  /// Default-on, subject to the one per-session sampling roll, shed second.
  standard,

  /// Off by default, opt-in, shed first. High-volume or privacy-sensitive
  /// variants of signals the `standard` tier already carries.
  diagnostic,
}

/// What a consumer may switch on or off.
///
/// **Closed at the `essential` boundary on purpose.** There is no `crash`,
/// `session`, `errors` or `profile` member, and adding one is a decision about
/// what a consumer may switch off — not a gap in an enumeration. An SDK that
/// reports no crashes must never be indistinguishable from one configured not
/// to; a supported switch manufacturing that signature is camouflage for the
/// next never-delivered-crash defect. Do not complete this enum for symmetry.
///
/// Developer-declared signal (`trackEvent`, `trackMetric`, …) gets no member
/// either: it already has a switch, and it is the call site.
enum Capture {
  // ---- standard tier (default-on) ----
  http,
  navigation,
  screenLoad,
  actions,
  frames,
  health,
  connectivity,
  lifecycle,

  // ---- diagnostic tier (opt-in) ----
  swipes,
  interactionCoordinates,
  httpQueryString,
  deviceFingerprint,
  accessibilityContext,
  lifecycleTransitions,
  longTask,
  screenWindowedFrames,
}

/// The tier each [Capture] belongs to. Every member is `standard` or
/// `diagnostic` — see the note on [Capture] for why none is `essential`.
const Map<Capture, CollectionTier> kCaptureTiers = {
  Capture.http: CollectionTier.standard,
  Capture.navigation: CollectionTier.standard,
  Capture.screenLoad: CollectionTier.standard,
  Capture.actions: CollectionTier.standard,
  Capture.frames: CollectionTier.standard,
  Capture.health: CollectionTier.standard,
  Capture.connectivity: CollectionTier.standard,
  Capture.lifecycle: CollectionTier.standard,
  Capture.swipes: CollectionTier.diagnostic,
  Capture.interactionCoordinates: CollectionTier.diagnostic,
  Capture.httpQueryString: CollectionTier.diagnostic,
  Capture.deviceFingerprint: CollectionTier.diagnostic,
  Capture.accessibilityContext: CollectionTier.diagnostic,
  Capture.lifecycleTransitions: CollectionTier.diagnostic,
  Capture.longTask: CollectionTier.diagnostic,
  Capture.screenWindowedFrames: CollectionTier.diagnostic,
};
