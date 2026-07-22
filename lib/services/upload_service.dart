import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

/// Upload state emitted by [UploadService.statusStream].
class UploadStatus {
  final String key;
  final String phase; // "uploading", "processing", "done", "error"
  final String message;
  final String filename;
  final Map<String, dynamic>? result;
  final DateTime startedAt;

  const UploadStatus({
    required this.key,
    required this.phase,
    required this.message,
    this.filename = '',
    this.result,
    required this.startedAt,
  });

  Duration get elapsed => DateTime.now().difference(startedAt);

  String get elapsedText {
    final e = elapsed;
    if (e.inSeconds < 60) return '${e.inSeconds}s';
    if (e.inMinutes < 60) return '${e.inMinutes}m ${e.inSeconds % 60}s';
    return '${e.inHours}h ${e.inMinutes % 60}m';
  }
}

/// Singleton — survives navigation, app lifecycle events.
///
/// Flow:
///   1. startUpload(bytes, filename, artist, title)
///      → POST to Modal align_from_file → get {status:"processing", key}
///      → store key in SharedPreferences
///      → begin polling align_file_status?key=...
///   2. poll loop (every 10s) until result or error
///   3. on result → cache locally, remove key from prefs, emit "done"
///   4. on app reopen → resumePendingUploads() checks prefs, resumes polls
class UploadService {
  UploadService._();
  static final UploadService _instance = UploadService._();
  static UploadService get instance => _instance;

  static const _modalFileUrl =
      'https://romaniv1437--chromic-trainer-split-v3-align-from-file.modal.run';
  static const _modalStatusUrl =
      'https://romaniv1437--chromic-trainer-split-v3-align-file-status.modal.run';
  static const _prefsKey = 'pending_upload_keys';
  static const _pollInterval = Duration(seconds: 10);

  final _statusController = StreamController<UploadStatus>.broadcast();
  Stream<UploadStatus> get statusStream => _statusController.stream;

  final Map<String, Timer> _pollTimers = {};
  final Map<String, UploadStatus> _activeUploads = {};
  UploadStatus? _latest;

  /// Current status (null if no upload in progress).
  UploadStatus? get latest => _latest;

  /// Start a fire-and-forget upload. Returns the content-hash key immediately.
  Future<String> startUpload(
    List<int> bytes,
    String filename,
    String artist,
    String title,
  ) async {
    final startedAt = DateTime.now();

    // 1) POST file to Modal
    _emit(UploadStatus(
      key: '',
      phase: 'uploading',
      message: 'Uploading...',
      filename: filename,
      startedAt: startedAt,
    ));

    final request = http.MultipartRequest('POST', Uri.parse(_modalFileUrl));
    request.headers['x-chromic-token'] = 'super-secret-chromic-string-1437';
    request.files.add(http.MultipartFile.fromBytes(
      'file',
      bytes,
      filename: filename,
    ));
    request.fields['artist'] = artist;
    request.fields['title'] = title;

    final streamedResp = await request.send();
    final body = await streamedResp.stream.bytesToString();

    if (streamedResp.statusCode != 200) {
      _emit(UploadStatus(
        key: '',
        phase: 'error',
        message: 'Server error (${streamedResp.statusCode})',
        filename: filename,
        startedAt: startedAt,
      ));
      throw Exception(body);
    }

    final data = jsonDecode(body) as Map<String, dynamic>;
    if (data['status'] == 'error') {
      _emit(UploadStatus(
        key: '',
        phase: 'error',
        message: data['error']?.toString() ?? 'Unknown error',
        filename: filename,
        startedAt: startedAt,
      ));
      throw Exception(data['error']);
    }

    final key = data['key'] as String;
    print('[UploadService] Got key: $key');

    // 2) Store key in SharedPreferences
    await _addPendingKey(key);

    // 3) Start polling
    final processing = UploadStatus(
      key: key,
      phase: 'processing',
      message: 'Preparing AI models...',
      filename: filename,
      startedAt: startedAt,
    );
    _activeUploads[key] = processing;
    _emit(processing);
    _schedulePoll(key);

    return key;
  }

  void _emit(UploadStatus status) {
    _latest = status;
    _statusController.add(status);
  }

  void _schedulePoll(String key) {
    _pollTimers[key]?.cancel();
    _pollTimers[key] = Timer(_pollInterval, () => _poll(key));
  }

  Future<void> _poll(String key) async {
    if (!_activeUploads.containsKey(key)) return; // cancelled

    try {
      final uri = Uri.parse('$_modalStatusUrl?key=$key');
      final resp = await http.get(
        uri,
        headers: {'x-chromic-token': 'super-secret-chromic-string-1437'},
      );

      if (resp.statusCode != 200) {
        _schedulePoll(key); // retry
        return;
      }

      final data = jsonDecode(resp.body) as Map<String, dynamic>;
      final status = data['status'] as String?;

      if (status == 'processing') {
        // Phase-aware progress message
        final active = _activeUploads[key]!;
        final elapsed = active.elapsed.inSeconds;
        final fn = active.filename;
        String msg;
        if (elapsed < 30) {
          msg = 'Warming up AI models…';
        } else if (elapsed < 90) {
          msg = 'Transcribing audio…';
        } else if (elapsed < 180) {
          msg = 'Generating haptics…';
        } else if (elapsed < 360) {
          msg = 'Fine-tuning alignment…';
        } else {
          msg = 'Almost done…';
        }
        final update = UploadStatus(
          key: key,
          phase: 'processing',
          message: msg,
          filename: fn,
          startedAt: active.startedAt,
        );
        _activeUploads[key] = update;
        _emit(update);
        _schedulePoll(key);
      } else if (status == 'success') {
        // Done!
        _pollTimers.remove(key)?.cancel();
        final active = _activeUploads[key];
        final done = UploadStatus(
          key: key,
          phase: 'done',
          message: 'Ready!',
          filename: active?.filename ?? '',
          result: data,
          startedAt: active?.startedAt ?? DateTime.now(),
        );
        _activeUploads.remove(key);
        await _removePendingKey(key);
        _emit(done);
        print('[UploadService] Done for key: $key');
      } else {
        // Error
        _pollTimers.remove(key)?.cancel();
        final active = _activeUploads[key];
        final err = UploadStatus(
          key: key,
          phase: 'error',
          message: data['error']?.toString() ?? 'Alignment failed',
          filename: active?.filename ?? '',
          startedAt: active?.startedAt ?? DateTime.now(),
        );
        _activeUploads.remove(key);
        await _removePendingKey(key);
        _emit(err);
      }
    } catch (e) {
      print('[UploadService] Poll error for $key: $e');
      _schedulePoll(key); // retry on network error
    }
  }

  /// Cancel an in-progress upload. Emits null to clear the banner.
  void cancel(String key) {
    _pollTimers.remove(key)?.cancel();
    _activeUploads.remove(key);
    _removePendingKey(key);
    _latest = null;
  }

  /// Called on app start — resume polling for any interrupted uploads.
  Future<void> resumePendingUploads() async {
    final prefs = await SharedPreferences.getInstance();
    final keys = prefs.getStringList(_prefsKey) ?? [];
    print('[UploadService] Resuming ${keys.length} pending uploads: $keys');

    for (final key in keys) {
      if (_activeUploads.containsKey(key)) continue;
      final status = UploadStatus(
        key: key,
        phase: 'processing',
        message: 'Resuming…',
        filename: '',
        startedAt: DateTime.now(),
      );
      _activeUploads[key] = status;
      _emit(status);
      _poll(key); // immediate first poll, then 10s intervals
    }
  }

  Future<void> _addPendingKey(String key) async {
    final prefs = await SharedPreferences.getInstance();
    final keys = prefs.getStringList(_prefsKey) ?? [];
    if (!keys.contains(key)) {
      keys.add(key);
      await prefs.setStringList(_prefsKey, keys);
    }
  }

  Future<void> _removePendingKey(String key) async {
    final prefs = await SharedPreferences.getInstance();
    final keys = prefs.getStringList(_prefsKey) ?? [];
    keys.remove(key);
    await prefs.setStringList(_prefsKey, keys);
  }

  void dispose() {
    for (final t in _pollTimers.values) {
      t.cancel();
    }
    _pollTimers.clear();
    _statusController.close();
  }
}
