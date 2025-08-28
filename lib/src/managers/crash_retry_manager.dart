// lib/src/managers/crash_retry_manager.dart

import 'dart:async';
import 'dart:math';

import '../storage/crash_storage.dart';
import '../http/json_http_client.dart';

/// Manages retry logic for failed crash reports
class CrashRetryManager {
  final CrashStorage _crashStorage;
  final JsonHttpClient _httpClient;
  final bool _debugMode;
  
  static const int _maxRetries = 3;
  static const Duration _baseRetryDelay = Duration(minutes: 1);
  static const Duration _maxRetryDelay = Duration(hours: 1);
  
  Timer? _retryTimer;
  bool _isRetrying = false;

  CrashRetryManager(
    this._crashStorage,
    this._httpClient, {
    bool debugMode = false,
  }) : _debugMode = debugMode;

  /// Start the retry mechanism
  void startRetryLoop() {
    if (_retryTimer?.isActive == true) return;
    
    _scheduleNextRetry(Duration(seconds: 30)); // Initial check after 30 seconds
    
    if (_debugMode) {
      print('🔄 Crash retry manager started');
    }
  }

  /// Stop the retry mechanism
  void stopRetryLoop() {
    _retryTimer?.cancel();
    _retryTimer = null;
    
    if (_debugMode) {
      print('⏹️ Crash retry manager stopped');
    }
  }

  /// Schedule the next retry attempt
  void _scheduleNextRetry(Duration delay) {
    _retryTimer?.cancel();
    _retryTimer = Timer(delay, _performRetryAttempt);
  }

  /// Perform a retry attempt for stored crashes
  Future<void> _performRetryAttempt() async {
    if (_isRetrying) return;
    
    _isRetrying = true;
    
    try {
      final storedCrashes = await _crashStorage.getStoredCrashes();
      
      if (storedCrashes.isEmpty) {
        // No crashes to retry, check again in 5 minutes
        _scheduleNextRetry(Duration(minutes: 5));
        return;
      }

      if (_debugMode) {
        print('🔄 Retrying ${storedCrashes.length} stored crashes');
      }

      int successCount = 0;
      int failureCount = 0;

      for (final crashData in storedCrashes) {
        final storage = crashData['storage'] as Map<String, dynamic>?;
        final filename = storage?['filename'] as String?;
        final retryCount = storage?['retry_count'] as int? ?? 0;

        if (filename == null) continue;

        // Skip if max retries exceeded
        if (retryCount >= _maxRetries) {
          if (_debugMode) {
            print('⚠️ Max retries exceeded for $filename, deleting');
          }
          await _crashStorage.deleteCrash(filename);
          continue;
        }

        // Attempt to send the crash
        final success = await _retrySingleCrash(crashData, filename, retryCount);
        
        if (success) {
          successCount++;
          await _crashStorage.deleteCrash(filename);
        } else {
          failureCount++;
          await _crashStorage.updateRetryCount(filename, retryCount + 1);
        }

        // Small delay between retries to avoid overwhelming the server
        await Future.delayed(Duration(milliseconds: 100));
      }

      if (_debugMode) {
        print('✅ Retry results: $successCount successful, $failureCount failed');
      }

      // Schedule next retry with exponential backoff
      final nextDelay = _calculateNextRetryDelay(failureCount > 0);
      _scheduleNextRetry(nextDelay);

    } catch (e) {
      if (_debugMode) {
        print('⚠️ Error during retry attempt: $e');
      }
      // Retry again in 2 minutes on error
      _scheduleNextRetry(Duration(minutes: 2));
    } finally {
      _isRetrying = false;
    }
  }

  /// Retry sending a single crash
  Future<bool> _retrySingleCrash(
    Map<String, dynamic> crashData,
    String filename,
    int currentRetryCount,
  ) async {
    try {
      // Remove storage metadata before sending
      final cleanCrashData = Map<String, dynamic>.from(crashData);
      cleanCrashData.remove('storage');

      // Add retry metadata
      cleanCrashData['retry_info'] = {
        'retry_count': currentRetryCount + 1,
        'max_retries': _maxRetries,
        'retry_at': DateTime.now().toIso8601String(),
      };

      await _httpClient.sendTelemetryData(cleanCrashData);

      if (_debugMode) {
        print('✅ Error report retry successful: $filename');
        print('   📊 Error: ${cleanCrashData['error']}');
        if (cleanCrashData['fingerprint'] != null) {
          print('   🔍 Fingerprint: ${cleanCrashData['fingerprint']}');
        }
        print('   🔄 Retry attempt: ${currentRetryCount + 1}/$_maxRetries');
        if (cleanCrashData['attributes']?['user.id'] != null) {
          print('   👤 User: ${cleanCrashData['attributes']['user.id']}');
        }
        print('   ⏰ Retry timestamp: ${cleanCrashData['retry_info']['retry_at']}');
      }

      return true;
    } catch (e) {
      if (_debugMode) {
        print('❌ Failed to retry error report $filename: $e');
      }
      return false;
    }
  }

  /// Calculate next retry delay with exponential backoff
  Duration _calculateNextRetryDelay(bool hasFailures) {
    if (!hasFailures) {
      // No failures, check again in 5 minutes
      return Duration(minutes: 5);
    }

    // Exponential backoff: 1min, 2min, 4min, 8min, up to 1 hour
    final delayMinutes = min(
      _baseRetryDelay.inMinutes * pow(2, Random().nextInt(3)),
      _maxRetryDelay.inMinutes,
    );

    return Duration(minutes: delayMinutes.toInt());
  }

  /// Force retry all stored crashes immediately
  Future<Map<String, int>> forceRetryAll() async {
    if (_debugMode) {
      print('🚀 Force retrying all stored crashes');
    }

    final storedCrashes = await _crashStorage.getStoredCrashes();
    int successCount = 0;
    int failureCount = 0;
    int skippedCount = 0;

    for (final crashData in storedCrashes) {
      final storage = crashData['storage'] as Map<String, dynamic>?;
      final filename = storage?['filename'] as String?;
      final retryCount = storage?['retry_count'] as int? ?? 0;

      if (filename == null) {
        skippedCount++;
        continue;
      }

      if (retryCount >= _maxRetries) {
        skippedCount++;
        await _crashStorage.deleteCrash(filename);
        continue;
      }

      final success = await _retrySingleCrash(crashData, filename, retryCount);
      
      if (success) {
        successCount++;
        await _crashStorage.deleteCrash(filename);
      } else {
        failureCount++;
        await _crashStorage.updateRetryCount(filename, retryCount + 1);
      }
    }

    return {
      'success': successCount,
      'failure': failureCount,
      'skipped': skippedCount,
    };
  }

  /// Get retry manager status
  Map<String, dynamic> getStatus() {
    return {
      'is_active': _retryTimer?.isActive ?? false,
      'is_retrying': _isRetrying,
      'max_retries': _maxRetries,
      'base_retry_delay_minutes': _baseRetryDelay.inMinutes,
      'max_retry_delay_minutes': _maxRetryDelay.inMinutes,
    };
  }

  /// Dispose resources
  void dispose() {
    stopRetryLoop();
  }
}
