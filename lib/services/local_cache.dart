import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';

/// SHA-256‑based config + audio cache for file‑upload tracks.
///
/// Layout inside getApplicationDocumentsDirectory:
///   cache/{sha256}.json   — Modal alignment config
///   audio/{sha256}.{ext}  — permanent audio copy
class LocalCache {
  LocalCache._();

  /// Compute SHA‑256 hex digest of file bytes.
  static Future<String> sha256OfFile(File file) async {
    final bytes = await file.readAsBytes();
    return sha256.convert(bytes).toString();
  }

  /// Compute SHA‑256 hex digest of bytes in memory (no re‑read).
  static String sha256OfBytes(List<int> bytes) {
    return sha256.convert(bytes).toString();
  }

  // ── Config cache ────────────────────────────────────────────────

  /// Returns cached alignment JSON or null.
  static Future<Map<String, dynamic>?> loadConfig(String sha256) async {
    final dir = await getApplicationDocumentsDirectory();
    final cacheDir = Directory('${dir.path}/cache');
    final file = File('${cacheDir.path}/$sha256.json');
    if (!await file.exists()) return null;
    try {
      return jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    } catch (_) {
      // Corrupt — delete and pretend miss
      await file.delete();
      return null;
    }
  }

  /// Persist alignment JSON keyed by SHA‑256.
  static Future<void> saveConfig(String sha256, Map<String, dynamic> data) async {
    final dir = await getApplicationDocumentsDirectory();
    final cacheDir = Directory('${dir.path}/cache');
    await cacheDir.create(recursive: true);
    await File('${cacheDir.path}/$sha256.json')
        .writeAsString(jsonEncode(data));
  }

  // ── Audio persistence ───────────────────────────────────────────

  /// Returns path to permanently‑stored audio file (or null).
  static Future<String?> audioPath(String sha256) async {
    final dir = await getApplicationDocumentsDirectory();
    final audioDir = Directory('${dir.path}/audio');
    if (!await audioDir.exists()) return null;

    final entries = await audioDir.list().toList();
    for (final e in entries) {
      final name = e.path.split('/').last;
      if (name.startsWith(sha256)) return e.path;
    }
    return null;
  }

  /// Copy source file into `audio/{sha256}.{ext}` and return the
  /// permanent path.  If file already exists, return existing path.
  static Future<String> persistAudio({
    required String sha256,
    required File sourceFile,
    required String originalName,
  }) async {
    final ext = originalName.contains('.')
        ? originalName.split('.').last
        : 'm4a';

    final dir = await getApplicationDocumentsDirectory();
    final audioDir = Directory('${dir.path}/audio');

    // Check if already persisted
    final existing = await audioPath(sha256);
    if (existing != null) return existing;

    await audioDir.create(recursive: true);
    final dest = File('${audioDir.path}/$sha256.$ext');
    await sourceFile.copy(dest.path);
    return dest.path;
  }

  /// Get the extension from a file name.
  static String extOf(String name) {
    final dot = name.lastIndexOf('.');
    return dot >= 0 ? name.substring(dot) : '.m4a';
  }

  // ── Haptics check ───────────────────────────────────────────────

  /// Whether cached config contains haptics data.
  static bool hasHaptics(Map<String, dynamic> config) {
    final h = config['haptics'];
    if (h == null) return false;
    if (h is Map) return (h['events'] as List?)?.isNotEmpty == true;
    return false;
  }
}
