// test/helpers/test_identity.dart
//
// The one batch identity tests hand a Pipeline. Pipeline requires one because a
// production envelope without `device_id` is a collector 400 (contract C6).

import 'package:edge_telemetry_flutter/src/core/wire_canon.dart';

const BatchIdentity kTestIdentity = (
  deviceId: 'device_abc',
  app: {
    'name': 'Test App',
    'package_name': 'com.example.test',
    'platform': 'android',
    'version': '1.0.0',
    'build_number': '1',
  },
);

/// Contract 4.0.0 R3: the envelope is closed at exactly these keys, in order.
/// A literal on purpose — asserting against a production constant would pass
/// whatever that constant said.
const List<String> kR3EnvelopeKeys = [
  'type',
  'contract_version',
  'timestamp',
  'batch_size',
  'device_id',
  'sdk',
  'app',
  'events',
];
