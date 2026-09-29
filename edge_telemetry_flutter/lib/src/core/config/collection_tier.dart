// lib/src/core/config/collection_tier.dart
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
  http(CollectionTier.standard),
  navigation(CollectionTier.standard),
  screenLoad(CollectionTier.standard),
  actions(CollectionTier.standard),
  frames(CollectionTier.standard),
  health(CollectionTier.standard),
  connectivity(CollectionTier.standard),
  lifecycle(CollectionTier.standard),

  // ---- diagnostic tier (opt-in) ----
  swipes(CollectionTier.diagnostic),
  interactionCoordinates(CollectionTier.diagnostic),
  httpQueryString(CollectionTier.diagnostic),
  httpPhaseTiming(CollectionTier.diagnostic),
  deviceFingerprint(CollectionTier.diagnostic),
  accessibilityContext(CollectionTier.diagnostic),
  lifecycleTransitions(CollectionTier.diagnostic),
  longTask(CollectionTier.diagnostic),
  screenWindowedFrames(CollectionTier.diagnostic);

  const Capture(this.tier);

  /// The tier this capture belongs to. Every member is `standard` or
  /// `diagnostic` — see the note above for why none is `essential`.
  final CollectionTier tier;
}
