// lib/edge_telemetry_flutter.dart
//
// Barrel: EXPORTS ONLY. The EdgeTelemetry facade + public models. No logic —
// the god-object is gone, split into the 5-layer core under lib/src/.

export 'src/facade/edge_telemetry.dart' show EdgeTelemetry;
export 'src/core/config/telemetry_config.dart' show TelemetryConfig;
export 'src/core/models/breadcrumb.dart' show Breadcrumb, BreadcrumbLevel;
export 'src/core/models/generated_report.dart';
export 'src/core/models/report_data.dart';
export 'src/core/models/telemetry_session.dart';
export 'src/widgets/edge_navigation_observer.dart' show EdgeNavigationObserver;
export 'src/capture/http_overrides.dart' show HttpRequestTelemetry;
