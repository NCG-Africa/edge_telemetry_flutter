// lib/src/http/json_http_client.dart

import 'dart:convert';
import 'dart:io';

class JsonHttpClient {
  final String endpoint;
  final HttpClient _httpClient;

  JsonHttpClient({required this.endpoint}) : _httpClient = HttpClient();

  Future<bool> sendTelemetryData(Map<String, dynamic> data) async {
    try {
      final uri = Uri.parse(endpoint);
      final request = await _httpClient.postUrl(uri);

      request.headers.set('Content-Type', 'application/json');

      final jsonString = json.encode(data);
      request.write(jsonString);

      final response = await request.close();

      if (response.statusCode >= 200 && response.statusCode < 300) {
        print('✅ Sent telemetry data successfully');
        return true;
      } else {
        print('❌ Failed: HTTP ${response.statusCode}');
        return false;
      }
    } catch (e) {
      print('❌ Error: $e');
      return false;
    }
  }

  void dispose() {
    _httpClient.close();
  }
}
