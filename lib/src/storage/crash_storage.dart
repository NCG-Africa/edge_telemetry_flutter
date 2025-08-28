// lib/src/storage/crash_storage.dart

import 'dart:convert';
import 'dart:io';
import 'package:path_provider/path_provider.dart';

/// Offline storage for crash reports when network is unavailable
class CrashStorage {
  static const String _crashDir = 'edge_telemetry_crashes';
  static const String _filePrefix = 'crash_';
  static const int _maxStoredCrashes = 100;
  
  final bool _debugMode;
  Directory? _storageDir;

  CrashStorage({bool debugMode = false}) : _debugMode = debugMode;

  /// Initialize crash storage directory
  Future<void> initialize() async {
    try {
      final appDir = await getApplicationDocumentsDirectory();
      _storageDir = Directory('${appDir.path}/$_crashDir');
      
      if (!await _storageDir!.exists()) {
        await _storageDir!.create(recursive: true);
        if (_debugMode) {
          print('📁 Created crash storage directory: ${_storageDir!.path}');
        }
      }
    } catch (e) {
      if (_debugMode) {
        print('⚠️ Failed to initialize crash storage: $e');
      }
    }
  }

  /// Store crash data offline
  Future<String?> storeCrash(Map<String, dynamic> crashData) async {
    if (_storageDir == null) {
      await initialize();
    }

    try {
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final filename = '$_filePrefix$timestamp.json';
      final file = File('${_storageDir!.path}/$filename');

      // Add storage metadata
      final enrichedCrashData = {
        ...crashData,
        'storage': {
          'stored_at': DateTime.now().toIso8601String(),
          'filename': filename,
          'retry_count': 0,
        }
      };

      await file.writeAsString(jsonEncode(enrichedCrashData));

      if (_debugMode) {
        print('💾 Stored crash offline: $filename');
      }

      // Clean up old crashes if we exceed the limit
      await _cleanupOldCrashes();

      return filename;
    } catch (e) {
      if (_debugMode) {
        print('⚠️ Failed to store crash: $e');
      }
      return null;
    }
  }

  /// Get all stored crashes
  Future<List<Map<String, dynamic>>> getStoredCrashes() async {
    if (_storageDir == null) {
      await initialize();
    }

    try {
      final files = await _storageDir!
          .list()
          .where((entity) => entity is File && entity.path.contains(_filePrefix))
          .cast<File>()
          .toList();

      final crashes = <Map<String, dynamic>>[];
      
      for (final file in files) {
        try {
          final content = await file.readAsString();
          final crashData = jsonDecode(content) as Map<String, dynamic>;
          crashes.add(crashData);
        } catch (e) {
          if (_debugMode) {
            print('⚠️ Failed to read crash file ${file.path}: $e');
          }
          // Delete corrupted file
          await file.delete();
        }
      }

      // Sort by stored timestamp (newest first)
      crashes.sort((a, b) {
        final aTime = a['storage']?['stored_at'] as String?;
        final bTime = b['storage']?['stored_at'] as String?;
        if (aTime == null || bTime == null) return 0;
        return DateTime.parse(bTime).compareTo(DateTime.parse(aTime));
      });

      return crashes;
    } catch (e) {
      if (_debugMode) {
        print('⚠️ Failed to get stored crashes: $e');
      }
      return [];
    }
  }

  /// Delete a specific crash file
  Future<bool> deleteCrash(String filename) async {
    if (_storageDir == null) return false;

    try {
      final file = File('${_storageDir!.path}/$filename');
      if (await file.exists()) {
        await file.delete();
        if (_debugMode) {
          print('🗑️ Deleted crash file: $filename');
        }
        return true;
      }
    } catch (e) {
      if (_debugMode) {
        print('⚠️ Failed to delete crash file $filename: $e');
      }
    }
    return false;
  }

  /// Update retry count for a crash
  Future<bool> updateRetryCount(String filename, int retryCount) async {
    if (_storageDir == null) return false;

    try {
      final file = File('${_storageDir!.path}/$filename');
      if (await file.exists()) {
        final content = await file.readAsString();
        final crashData = jsonDecode(content) as Map<String, dynamic>;
        
        // Update retry count
        crashData['storage'] = {
          ...crashData['storage'] as Map<String, dynamic>,
          'retry_count': retryCount,
          'last_retry_at': DateTime.now().toIso8601String(),
        };

        await file.writeAsString(jsonEncode(crashData));
        return true;
      }
    } catch (e) {
      if (_debugMode) {
        print('⚠️ Failed to update retry count for $filename: $e');
      }
    }
    return false;
  }

  /// Clean up old crashes to stay within limit
  Future<void> _cleanupOldCrashes() async {
    try {
      final files = await _storageDir!
          .list()
          .where((entity) => entity is File && entity.path.contains(_filePrefix))
          .cast<File>()
          .toList();

      if (files.length <= _maxStoredCrashes) return;

      // Sort by modification time (oldest first)
      files.sort((a, b) => a.statSync().modified.compareTo(b.statSync().modified));

      // Delete oldest files
      final filesToDelete = files.take(files.length - _maxStoredCrashes);
      for (final file in filesToDelete) {
        await file.delete();
        if (_debugMode) {
          print('🧹 Cleaned up old crash file: ${file.path}');
        }
      }
    } catch (e) {
      if (_debugMode) {
        print('⚠️ Failed to cleanup old crashes: $e');
      }
    }
  }

  /// Get storage statistics
  Map<String, dynamic> getStorageStats() {
    return {
      'max_crashes': _maxStoredCrashes,
      'storage_dir': _storageDir?.path ?? 'not_initialized',
      'initialized': _storageDir != null,
    };
  }

  /// Clear all stored crashes
  Future<int> clearAll() async {
    if (_storageDir == null) return 0;

    try {
      final files = await _storageDir!
          .list()
          .where((entity) => entity is File && entity.path.contains(_filePrefix))
          .cast<File>()
          .toList();

      int deletedCount = 0;
      for (final file in files) {
        await file.delete();
        deletedCount++;
      }

      if (_debugMode) {
        print('🧹 Cleared $deletedCount stored crashes');
      }

      return deletedCount;
    } catch (e) {
      if (_debugMode) {
        print('⚠️ Failed to clear stored crashes: $e');
      }
      return 0;
    }
  }
}
