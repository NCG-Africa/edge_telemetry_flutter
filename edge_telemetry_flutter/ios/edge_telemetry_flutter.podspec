#
# edge_telemetry_flutter — iOS plugin (#27).
# MetricKit crash/hang diagnostics surfaced over the
# `edge_telemetry/native_crash` MethodChannel. iOS 14 hard floor (MetricKit
# diagnostic payloads require iOS 14) — this is the Podfile floor bump the v2
# migration guide calls out.
#
Pod::Spec.new do |s|
  s.name             = 'edge_telemetry_flutter'
  s.version          = '1.6.0'
  s.summary          = 'iOS MetricKit native crash capture for edge_telemetry_flutter.'
  s.description      = <<-DESC
Captures native crashes (MXCrashDiagnostic) and hangs (MXHangDiagnostic) via
Apple MetricKit — zero hand-rolled signal handlers — and drains them to Dart
on next launch over the edge_telemetry/native_crash channel.
                       DESC
  s.homepage         = 'https://github.com/NCG-Africa/edge_telemetry_flutter'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'NCG Africa' => 'movaaraconsult@gmail.com' }
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*'
  s.dependency 'Flutter'
  s.platform = :ios, '14.0'
  s.swift_version = '5.0'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
end
