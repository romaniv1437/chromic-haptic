import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/foundation.dart' show VoidCallback, kIsWeb;
import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:http/http.dart' as http;
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';
import 'widgets/lyric_painter.dart';
import 'widgets/bloom_widget.dart';

import 'widgets/haptic_timeline.dart';
import 'models/lyric_models.dart';
import 'engine/haptic_engine.dart';
import 'services/local_cache.dart';
import 'services/upload_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const ChromicHapticApp());
}

class ChromicHapticApp extends StatelessWidget {
  const ChromicHapticApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Chromic Haptic',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xFF0A0A12),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF4CAF50),
        ),
      ),
      home: const HomeScreen(),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// HOME SCREEN — URL input + GitHub DB lookup + Modal fallback
// ═══════════════════════════════════════════════════════════════════════════

/// Universal thumbnail widget: handles http(s):// URLs, file:// paths, and data: URIs.
Widget thumbnailImage(String src,
    {double width = 40,
    double height = 40,
    BoxFit fit = BoxFit.cover,
    Widget? errorWidget}) {
  final fallback = errorWidget ??
      Container(
        width: width,
        height: height,
        color: const Color(0xFF1A1A2E),
        child: const Icon(Icons.music_note, color: Colors.white38, size: 20),
      );
  if (src.isEmpty) return fallback;

  Widget buildImage(ImageProvider provider) {
    return SizedBox(
      width: width,
      height: height,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child: Image(
            image: provider,
            width: width,
            height: height,
            fit: fit,
            errorBuilder: (_, __, ___) => fallback),
      ),
    );
  }

  if (src.startsWith('file://')) {
    final path = src.substring(7);
    final file = File(path);
    if (file.existsSync()) {
      return buildImage(FileImage(file));
    }
    return fallback;
  }
  if (src.startsWith('data:')) {
    try {
      final commaIdx = src.indexOf(',');
      if (commaIdx > 0) {
        final b64 = src.substring(commaIdx + 1).replaceAll(RegExp(r'\s'), '');
        final bytes = base64Decode(b64);
        return buildImage(MemoryImage(bytes));
      }
    } catch (_) {}
    return fallback;
  }
  return buildImage(NetworkImage(src));
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _urlController = TextEditingController();
  List<String> _localTracks = [];
  bool _loading = false;
  String _loadingMessage = '';
  UploadStatus? _uploadStatus;
  StreamSubscription<UploadStatus>? _uploadSub;

  static const _modalUrl =
      'https://romaniv1437--chromic-trainer-split-v3-align-from-url.modal.run';
  static const _filePickerChannel = MethodChannel('com.chromic/filepicker');
  static const _dbBase =
      'https://raw.githubusercontent.com/romaniv1437/chromic-engine-lyrics-database/main';
  static const _privacyUrl =
      'https://romaniv1437.github.io/chromic-haptic/privacy';

  Map<String, dynamic>? _cachedIndex;
  DateTime _indexFetchedAt = DateTime.fromMillisecondsSinceEpoch(0);
  List<Map<String, dynamic>> _history = [];

  @override
  void initState() {
    super.initState();
    _loadLocalTracks();
    _loadHistory();

    // Listen to upload status stream — survives navigation, widget rebuilds.
    _uploadSub = UploadService.instance.statusStream.listen(_onUploadStatus);

    // Resume any uploads that were interrupted (app killed mid-upload).
    UploadService.instance.resumePendingUploads();
  }

  void _onUploadStatus(UploadStatus status) {
    if (!mounted) return;
    setState(() => _uploadStatus = status);

    if (status.phase == 'done' && status.result != null) {
      _handleUploadDone(status);
    }
  }

  /// Called when UploadService delivers a finished result.
  Future<void> _handleUploadDone(UploadStatus status) async {
    final data = status.result!;
    final key = status.key;
    // key = "file:sha256:{hex}" → extract hex
    final fileHash = key.startsWith('file:sha256:') ? key.substring(12) : key;

    if (!mounted) return;

    // Persist thumbnail to disk.
    final rawThumb =
        ((data['meta'] as Map?) ?? const {})['thumbnail']?.toString() ?? '';
    final thumbPath = await _persistThumbnail(fileHash, rawThumb);
    if (thumbPath != rawThumb && data['meta'] is Map) {
      (data['meta'] as Map)['thumbnail'] = thumbPath;
    }

    // Persist config cache by SHA-256.
    await LocalCache.saveConfig(fileHash, data);

    // Inject local audio path.
    final permanentAudioPath = await LocalCache.audioPath(fileHash);
    final enriched = Map<String, dynamic>.from(data);
    enriched['_localAudioPath'] = permanentAudioPath ?? '';

    // Save to old-style cache for backwards compat.
    if (permanentAudioPath != null) {
      final cacheDir = await getApplicationDocumentsDirectory();
      final cacheFile = File('${cacheDir.path}/$fileHash.chromic.json');
      await cacheFile.writeAsString(jsonEncode(enriched));
    }

    if (!mounted) return;
    setState(() {
      _loading = false;
      _uploadStatus = null;
    });

    // Use Modal-extracted metadata (ffprobe).
    final metaTitle = _titleFromData(data, 'file://$fileHash');
    final displayTitle = (metaTitle != 'Local Track' && metaTitle.isNotEmpty)
        ? metaTitle
        : (data['meta']?['track_title']?.toString() ?? 'Local Track');
    _saveToHistory('file://$fileHash', displayTitle,
        artist: _metaStr(data, 'artist'),
        thumbnail: _metaStr(data, 'thumbnail'));

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => PlayerScreen(
          trackData: enriched,
          sourceTitle: displayTitle,
          trackUrl: 'file://$fileHash',
        ),
      ),
    );
  }

  // ── Local track storage (mobile/desktop only) ──

  Future<void> _loadLocalTracks() async {
    if (kIsWeb) return;
    try {
      final dir = await getApplicationDocumentsDirectory();
      final tracksDir = Directory('${dir.path}/tracks');
      if (await tracksDir.exists()) {
        final files = await tracksDir.list().toList();
        setState(() {
          _localTracks = files
              .where((f) => f.path.endsWith('.chromic.json'))
              .map(
                  (f) => f.path.split('/').last.replaceAll('.chromic.json', ''))
              .toList();
        });
      }
    } catch (_) {}
  }

  Future<String> _historyPath() async {
    final dir = await getApplicationDocumentsDirectory();
    return '${dir.path}/history.json';
  }

  Future<void> _pasteFromClipboard() async {
    try {
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      final text = data?.text;
      if (text != null && text.contains('soundcloud.com/')) {
        _urlController.text = text.trim();
        _loadFromUrl(text.trim());
      } else if (text != null) {
        _urlController.text = text.trim();
        _showSnack('Pasted. Press enter or tap Load to process.');
      }
    } catch (_) {
      _showSnack('Could not access clipboard');
    }
  }

  Future<void> _loadHistory() async {
    if (kIsWeb) return;
    try {
      final path = await _historyPath();
      final file = File(path);
      if (await file.exists()) {
        final list = jsonDecode(await file.readAsString()) as List<dynamic>;
        setState(() {
          _history = list.cast<Map<String, dynamic>>();
        });
      }
    } catch (_) {}
  }

  Future<void> _saveToHistory(String url, String title,
      {String artist = '', String thumbnail = ''}) async {
    if (kIsWeb) return;
    try {
      // Remove duplicate if exists, keep most recent
      _history.removeWhere((e) => e['url'] == url);
      _history.insert(0, {
        'url': url,
        'title': title,
        'artist': artist,
        'thumbnail': thumbnail,
        'date': DateTime.now().toIso8601String(),
      });
      // Cap at 50 entries
      if (_history.length > 50) _history = _history.sublist(0, 50);
      final path = await _historyPath();
      await File(path).writeAsString(jsonEncode(_history));
      if (mounted) setState(() {});
    } catch (_) {}
  }

  Future<void> _cacheTrack(String url, String jsonBody) async {
    if (kIsWeb) return;
    try {
      final dir = await getApplicationDocumentsDirectory();
      final tracksDir = Directory('${dir.path}/tracks');
      await tracksDir.create(recursive: true);

      // Inject source_url into cached JSON so deep-scan can find it later
      Map<String, dynamic> data;
      try {
        data = jsonDecode(jsonBody) as Map<String, dynamic>;
      } catch (_) {
        data = <String, dynamic>{};
      }
      data['source_url'] = url;
      final enriched = jsonEncode(data);

      final slug = url.replaceAll(RegExp(r'[^\w]'), '_').substring(0, 40);
      await File('${tracksDir.path}/$slug.chromic.json')
          .writeAsString(enriched);
      _loadLocalTracks();
    } catch (_) {}
  }

  void _showAboutDialog() {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A2E),
        title: const Text('Chromic Haptic',
            style: TextStyle(color: Color(0xFF4CAF50))),
        content: const Text(
          'Feel the music. Literally.\n\n'
          'Chromic converts music into tactile vibrations so Deaf and hard-of-hearing people can feel songs through their phone.\n\n'
          'Built in Ukraine 🇺🇦\n'
          'by Illia Romaniv, 2026',
          style: TextStyle(color: Colors.white70, height: 1.5),
        ),
        actions: [
          TextButton(
            onPressed: () => _openPrivacyPolicy(),
            child: const Text('Privacy Policy'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  Future<void> _openPrivacyPolicy() async {
    final uri = Uri.parse(_privacyUrl);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } else {
      _showSnack('Privacy: $_privacyUrl');
    }
  }

  Future<void> _openLocalTrack(String name) async {
    if (kIsWeb) return;
    try {
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/tracks/$name.chromic.json');
      if (!await file.exists()) return;
      final data = jsonDecode(await file.readAsString());
      // Save to history if track has a source URL
      if (data is Map<String, dynamic>) {
        final storedUrl = (data['source_url'] ??
            data['_sourcePath'] ??
            data['url']) as String?;
        if (storedUrl != null) {
          _saveToHistory(storedUrl, _titleFromData(data, storedUrl),
              artist: _metaStr(data, 'artist'),
              thumbnail: _metaStr(data, 'thumbnail'));
        }
      }
      if (!mounted) return;
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => PlayerScreen(trackData: data, sourceTitle: name),
        ),
      );
    } catch (_) {}
  }

  // ── GitHub DB lookup ──

  Future<Map<String, dynamic>?> _lookupInDb(String url) async {
    try {
      setState(() => _loadingMessage = '🔍 Searching database...');

      // Use cached index (re-fetch every 5 min)
      if (_cachedIndex == null ||
          DateTime.now().difference(_indexFetchedAt).inMinutes > 5) {
        print('[DB] Fetching index from $_dbBase/lyrics-db/index.json');
        final indexResp = await http
            .get(Uri.parse('$_dbBase/lyrics-db/index.json'))
            .timeout(const Duration(seconds: 15));
        print('[DB] Index status: ${indexResp.statusCode}');
        if (indexResp.statusCode != 200) {
          print('[DB] Index fetch failed: ${indexResp.statusCode}');
          return null;
        }
        _cachedIndex = jsonDecode(indexResp.body) as Map<String, dynamic>;
        _indexFetchedAt = DateTime.now();
        final regCount = (_cachedIndex!['registry'] as Map?)?.length ?? 0;
        final tracksArrCount = (_cachedIndex!['tracks'] as List?)?.length ?? 0;
        print(
            '[DB] Index cached: $regCount registry + $tracksArrCount tracks[] entries');
      } else {
        print(
            '[DB] Using cached index (${DateTime.now().difference(_indexFetchedAt).inMinutes}m old)');
      }

      final registry = _cachedIndex!['registry'] as Map<String, dynamic>? ?? {};

      // Normalize URL: strip query params, trailing slash
      final normalized = url
          .trim()
          .replaceAll(RegExp(r'[?&#].*$'), '')
          .replaceAll(RegExp(r'/+$'), '');
      print('[DB] Searching for: "$normalized"');

      for (final entry in registry.values) {
        final sourcePath = (entry['sourcePath'] as String? ?? '').trim();
        if (sourcePath.isEmpty) continue;

        final sourceNormalized = sourcePath
            .replaceAll(RegExp(r'[?&#].*$'), '')
            .replaceAll(RegExp(r'/+$'), '');

        if (sourceNormalized == normalized ||
            sourceNormalized.contains(normalized) ||
            normalized.contains(sourceNormalized)) {
          final filePath = entry['file'] as String?;
          if (filePath == null) continue;

          print('[DB] ✅ MATCH! sourcePath: $sourcePath → file: $filePath');
          final trackResp = await http
              .get(Uri.parse('$_dbBase/lyrics-db/$filePath'))
              .timeout(const Duration(seconds: 10));

          if (trackResp.statusCode == 200) {
            print('[DB] ✅ Track loaded: ${trackResp.body.length} bytes');
            final data = jsonDecode(trackResp.body) as Map<String, dynamic>;
            data['_sourcePath'] = sourcePath; // for audio download
            return data;
          } else {
            print('[DB] ❌ Track fetch failed: ${trackResp.statusCode}');
          }
        }
      }
      // Fallback: search tracks array (many SC tracks only here, not in registry)
      final tracksList = _cachedIndex!['tracks'] as List<dynamic>? ?? [];
      print(
          '[DB] Registry miss — searching ${tracksList.length} entries in tracks[]...');

      for (final entry in tracksList) {
        if (entry is! Map<String, dynamic>) continue;
        final sourcePath = (entry['sourcePath'] as String? ?? '').trim();
        if (sourcePath.isEmpty) continue;

        final sourceNormalized = sourcePath
            .replaceAll(RegExp(r'[?&#].*$'), '')
            .replaceAll(RegExp(r'/+$'), '');

        if (sourceNormalized == normalized ||
            sourceNormalized.contains(normalized) ||
            normalized.contains(sourceNormalized)) {
          final filePath = entry['file'] as String?;
          if (filePath == null) continue;

          print(
              '[DB] ✅ MATCH in tracks[]! sourcePath: $sourcePath → file: $filePath');
          final trackResp = await http
              .get(Uri.parse('$_dbBase/lyrics-db/$filePath'))
              .timeout(const Duration(seconds: 10));

          if (trackResp.statusCode == 200) {
            print('[DB] ✅ Track loaded: ${trackResp.body.length} bytes');
            final data = jsonDecode(trackResp.body) as Map<String, dynamic>;
            data['_sourcePath'] = sourcePath;
            return data;
          } else {
            print('[DB] ❌ Track fetch failed: ${trackResp.statusCode}');
          }
        }
      }

      print('[DB] ❌ No match for: "$normalized"');
    } catch (e, stack) {
      print('[DB] ❌ ERROR: $e');
      print('[DB] Stack: $stack');
    }
    return null;
  }

  String _metaStr(Map<String, dynamic> data, String field) {
    try {
      final meta = data['meta'] as Map<String, dynamic>?;
      return (meta?[field]?.toString() ?? '');
    } catch (_) {}
    return '';
  }

  String _titleFromData(Map<String, dynamic> data, String url) {
    try {
      final meta = data['meta'] as Map<String, dynamic>?;
      final title =
          meta?['title'] ?? meta?['trackTitle'] ?? meta?['track_title'];
      if (title != null && title is String && title.isNotEmpty) return title;
    } catch (_) {}
    // For file:// URLs without metadata, don't show the hash — use filename from config or fallback.
    if (url.startsWith('file://')) {
      try {
        final srcUrl = data['source_url']?.toString();
        if (srcUrl != null && srcUrl.isNotEmpty) {
          final clean = srcUrl
              .replaceAll(RegExp(r'[?&#].*$'), '')
              .replaceAll(RegExp(r'/+$'), '');
          return clean.split('/').last;
        }
      } catch (_) {}
      return 'Local Track';
    }
    // Fallback: extract last path segment from URL
    final clean =
        url.replaceAll(RegExp(r'[?&#].*$'), '').replaceAll(RegExp(r'/+$'), '');
    return clean.split('/').last;
  }

  bool _isSoundCloudUrl(String url) {
    return url.contains('soundcloud.com/');
  }

  // ── Main load flow: local cache → DB first → Modal fallback ──

  /// Dispatches history entry: file:// → local cache, otherwise → _loadFromUrl.
  Future<void> _loadFromHistoryEntry(String url) async {
    if (url.startsWith('file://')) {
      final fileHash = url.substring(7); // strip "file://"
      final config = await LocalCache.loadConfig(fileHash);
      if (config == null) {
        _showSnack('Cached config not found. Re-upload the file.');
        return;
      }
      final audioPath = await LocalCache.audioPath(fileHash);
      if (audioPath == null) {
        _showSnack('Cached audio not found. Re-upload the file.');
        return;
      }
      if (!LocalCache.hasHaptics(config)) {
        _showSnack('Incomplete cache. Re-upload the file for full processing.');
        return;
      }
      // Best title: config metadata → history stored title → filename → 'Local Track'.
      final histEntry = _history
          .cast<Map<String, dynamic>?>()
          .firstWhere((e) => e?['url'] == url, orElse: () => null);
      final storedTitle = histEntry?['title']?.toString();
      final metaTitle = _titleFromData(config, url);
      final title = (metaTitle != 'Local Track' && metaTitle.isNotEmpty)
          ? metaTitle
          : (storedTitle ?? metaTitle);
      _saveToHistory(url, title,
          artist: _metaStr(config, 'artist'),
          thumbnail: _metaStr(config, 'thumbnail'));
      _playFromCache(fileHash, config, audioPath, title);
      return;
    }
    // Regular SoundCloud URL
    await _loadFromUrl(url);
  }

  Future<void> _loadFromUrl(String url) async {
    if (url.trim().isEmpty) return;
    if (!_isSoundCloudUrl(url)) {
      _showSnack('Only SoundCloud links are supported');
      return;
    }
    setState(() => _loading = true);

    try {
      if (!kIsWeb) {
        final cachedJson = await _loadCachedTrack(url);
        if (cachedJson != null) {
          if (!mounted) return;
          setState(() => _loading = false);
          _showSnack('⚡ From cache');
          _saveToHistory(url, _titleFromData(cachedJson, url),
              artist: _metaStr(cachedJson, 'artist'),
              thumbnail: _metaStr(cachedJson, 'thumbnail'));
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => PlayerScreen(
                  trackData: cachedJson, sourceTitle: url, trackUrl: url),
            ),
          );
          return;
        }
      }

      // Step 1: Try GitHub DB first
      final cached = await _lookupInDb(url);
      if (cached != null) {
        if (!mounted) return;
        await _cacheTrack(url, jsonEncode(cached));
        setState(() => _loading = false);
        _showSnack('⚡ Found in database! Loading instantly...');
        _saveToHistory(url, _titleFromData(cached, url),
            artist: _metaStr(cached, 'artist'),
            thumbnail: _metaStr(cached, 'thumbnail'));
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => PlayerScreen(
                trackData: cached, sourceTitle: url, trackUrl: url),
          ),
        );
        return;
      }

      // Step 2: Fall back to Modal
      setState(() => _loadingMessage = '🔄 Generating with AI...');

      // Cold-start warmup: background health check + progress messages
      Timer(const Duration(seconds: 5), () {
        if (mounted) setState(() => _loadingMessage = '⏳ Warming up server...');
      });
      Timer(const Duration(seconds: 30), () {
        if (mounted)
          setState(() =>
              _loadingMessage = '⏳ Almost there... first request takes longer');
      });

      // Background health check to warm Modal before sending actual request
      http
          .get(Uri.parse(_modalUrl.replaceAll('/align_url', '/health')))
          .then((_) {})
          .catchError((_) {});

      final response = await http.post(Uri.parse(_modalUrl),
          body: jsonEncode({'track_url': url.trim(), 'haptics': true}),
          headers: {
            'Content-Type': 'application/json',
            'x-chromic-token': 'super-secret-chromic-string-1437',
          }).timeout(const Duration(minutes: 5));

      if (response.statusCode != 200) {
        _showSnack('Error ${response.statusCode}: ${response.body}');
        return;
      }

      final data = jsonDecode(response.body) as Map<String, dynamic>;
      await _cacheTrack(url, response.body);
      _saveToHistory(url, _titleFromData(data, url),
          artist: _metaStr(data, 'artist'),
          thumbnail: _metaStr(data, 'thumbnail'));

      if (!mounted) return;
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) =>
              PlayerScreen(trackData: data, sourceTitle: url, trackUrl: url),
        ),
      );
    } on TimeoutException {
      _showSnack('Modal timed out after 5 minutes (long tracks take time)');
    } catch (e) {
      String message;
      final s = e.toString();
      if (s.contains('timeout') || s.contains('Timeout')) {
        message = 'Server taking too long. Try again.';
      } else if (s.contains('SocketException') ||
          s.contains('Connection refused')) {
        message = 'No internet connection. Check your network.';
      } else if (s.contains('404')) {
        message = 'Track not found. Check the link.';
      } else {
        message = 'Could not process this track. Try another.';
      }
      _showSnack(message);
    } finally {
      if (mounted) {
        setState(() {
          _loading = false;
          _loadingMessage = '';
        });
      }
    }
  }

  Future<Map<String, dynamic>?> _loadCachedTrack(String url) async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final tracksDir = Directory('${dir.path}/tracks');
      if (!await tracksDir.exists()) return null;

      // Normalize: strip query params & trailing slash so the same track
      // matches regardless of ?si=... tracking garbage.
      final normalized = url
          .trim()
          .replaceAll(RegExp(r'[?&#].*$'), '')
          .replaceAll(RegExp(r'/+$'), '');

      // 1) Exact slug match (backwards-compatible, fast)
      final slug = url.replaceAll(RegExp(r'[^\w]'), '_').substring(0, 40);
      final exactFile = File('${tracksDir.path}/$slug.chromic.json');
      if (await exactFile.exists()) {
        try {
          final data = jsonDecode(await exactFile.readAsString())
              as Map<String, dynamic>;
          print('[CACHE] Exact slug match: $slug');
          return data;
        } catch (e) {
          print('[CACHE] Corrupt cache file: $slug — $e. Deleting.');
          await exactFile.delete();
        }
      }

      // 2) Deep scan: check all cached files for matching sourcePath/url
      final files = await tracksDir.list().toList();
      for (final f in files) {
        if (!f.path.endsWith('.chromic.json')) continue;
        if (f.path == exactFile.path) continue; // already checked
        try {
          final content = await File(f.path).readAsString();
          final data = jsonDecode(content) as Map<String, dynamic>;

          // Check if any stored URL field matches our normalized URL
          for (final key in ['source_url', '_sourcePath', 'url', 'sourceUrl']) {
            final stored = (data[key] as String?)?.trim() ?? '';
            if (stored.isEmpty) continue;
            final storedNorm = stored
                .replaceAll(RegExp(r'[?&#].*$'), '')
                .replaceAll(RegExp(r'/+$'), '');
            if (storedNorm == normalized) {
              print('[CACHE] Deep match via $key: ${f.path.split('/').last}');
              return data;
            }
          }
        } catch (_) {
          // Corrupt file — skip, will be cleaned up on next cache write
        }
      }
      print('[CACHE] No match for: $normalized');
    } catch (e) {
      print('[CACHE] Error: $e');
    }
    return null;
  }

  void _showSnack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  // ── Local file upload ──

  /// Native file picker via PlatformChannel → Modal align_from_file.
  /// Uses Android ActivityResultContracts.OpenDocument (no file_picker plugin).
  ///
  /// Flow: SHA‑256 → local cache → GitHub DB → Modal pipeline.
  /// Cached result includes haptics — same file replays instantly.

  Future<void> _loadFromFile() async {
    if (_loading) return;

    try {
      final result = await _filePickerChannel.invokeMethod<Map>('pickFile');
      if (result == null) return; // user cancelled

      final String path = result['path'] as String;
      final String name = result['name'] as String? ?? 'track.m4a';

      setState(() {
        _loading = true;
        _loadingMessage = '📤 Processing $name...';
      });

      final file = File(path);
      final bytes = await file.readAsBytes();
      if (bytes.isEmpty) throw Exception('File is empty');

      final fileHash = LocalCache.sha256OfBytes(bytes);
      final title = name.replaceAll(RegExp(r'\.[^.]+$'), '');

      // ── Persist audio to permanent storage (do this once, always) ──
      setState(() => _loadingMessage = '📁 Copying audio...');
      final permanentAudioPath = await LocalCache.persistAudio(
        sha256: fileHash,
        sourceFile: file,
        originalName: name,
      );

      // ═══ PATH 1: Local cache hit with haptics → instant ═══
      final cachedConfig = await LocalCache.loadConfig(fileHash);
      if (cachedConfig != null && LocalCache.hasHaptics(cachedConfig)) {
        _playFromCache(fileHash, cachedConfig, permanentAudioPath, title);
        return;
      }

      // ═══ PATH 2: Local cache hit, no haptics → full Modal reprocess ═══
      if (cachedConfig != null) {
        // Cache exists but incomplete — force full reprocess on Modal
        setState(
            () => _loadingMessage = '⚠️ Incomplete cache — regenerating...');
        await _fireAndForgetUpload(
            bytes, name, title, fileHash, permanentAudioPath);
        return;
      }

      // ═══ PATH 3: GitHub DB lookup ═══
      setState(() => _loadingMessage = '🔍 Searching database...');
      final dbEntry = await _lookupInGithubDB(fileHash, name);
      if (dbEntry != null) {
        final config = dbEntry['config'] as Map<String, dynamic>;
        final hasHaptics = LocalCache.hasHaptics(config);

        if (hasHaptics) {
          // ⚡ Found in DB with haptics — cache locally + instant play
          await LocalCache.saveConfig(fileHash, config);
          _playFromCache(fileHash, config, permanentAudioPath, title);
          return;
        }
        // Found in DB but no haptics — full reprocess (fresh lyrics + haptics)
        setState(
            () => _loadingMessage = '⚠️ Found in DB, regenerating haptics...');
        await _fireAndForgetUpload(
            bytes, name, title, fileHash, permanentAudioPath);
        return;
      }

      // ═══ PATH 4: Nothing found → full Modal pipeline ═══
      setState(
          () => _loadingMessage = '📤 Uploading to Modal (full pipeline)...');
      await _fireAndForgetUpload(
          bytes, name, title, fileHash, permanentAudioPath);
    } on TimeoutException {
      _showSnack('Modal took too long — try a shorter file');
    } catch (e) {
      _showSnack('Upload failed: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  // ── Helpers ──────────────────────────────────────────────────────

  /// Persist base64 data URI thumbnail to disk. Returns file:// path or original src unchanged.
  Future<String> _persistThumbnail(String sha256, String src) async {
    if (!src.startsWith('data:')) return src;
    try {
      final dir = await getApplicationDocumentsDirectory();
      final thumbDir = Directory('${dir.path}/thumbnails');
      await thumbDir.create(recursive: true);
      final commaIdx = src.indexOf(',');
      if (commaIdx < 0) return src;
      final bytes = base64Decode(
          src.substring(commaIdx + 1).replaceAll(RegExp(r'\s'), ''));
      final file = File('${thumbDir.path}/$sha256.jpg');
      if (!await file.exists()) {
        await file.writeAsBytes(bytes);
      }
      return 'file://${file.path}';
    } catch (_) {
      return src;
    }
  }

  /// Play track from cache immediately — no network needed.
  void _playFromCache(
    String fileHash,
    Map<String, dynamic> config,
    String audioPath,
    String title,
  ) async {
    if (!mounted) return;
    setState(() => _loading = false);

    // Persist thumbnail from base64 data URI to disk.
    final rawThumb =
        ((config['meta'] as Map?) ?? const {})['thumbnail']?.toString() ?? '';
    final thumbPath = await _persistThumbnail(fileHash, rawThumb);
    if (thumbPath != rawThumb && config['meta'] is Map) {
      (config['meta'] as Map)['thumbnail'] = thumbPath;
    }

    // Use config metadata title when available, fall back to passed title.
    final metaTitle = _titleFromData(config, 'file://$fileHash');
    final displayTitle = (metaTitle != 'Local Track' && metaTitle.isNotEmpty)
        ? metaTitle
        : title;
    _showSnack('⚡ Playing from cache');
    _saveToHistory('file://$fileHash', displayTitle,
        artist: _metaStr(config, 'artist'),
        thumbnail: _metaStr(config, 'thumbnail'));

    final enriched = Map<String, dynamic>.from(config);
    enriched['_localAudioPath'] = audioPath;

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => PlayerScreen(
          trackData: enriched,
          sourceTitle: title,
          trackUrl: 'file://$fileHash',
        ),
      ),
    );
  }

  /// Fire-and-forget upload: sends file to Modal, gets key back immediately,
  /// then UploadService polls in background. Survives app kill / navigation.
  Future<void> _fireAndForgetUpload(
    List<int> bytes,
    String name,
    String title,
    String fileHash,
    String permanentAudioPath,
  ) async {
    try {
      final key = await UploadService.instance.startUpload(
        bytes,
        name,
        '', // artist — Modal extracts via ffprobe
        title,
      );
      print('[HomeScreen] Upload started, key: $key');
      // Don't clear _loading — upload banner shows progress.
      // _onUploadStatus will call _handleUploadDone when finished.
    } catch (e) {
      if (!mounted) return;
      _showSnack('Upload failed: $e');
      setState(() {
        _loading = false;
        _uploadStatus = null;
      });
    }
  }

  /// Search GitHub DB by file SHA‑256 (registry) then by filename (index).
  /// Returns { config, trackId } or null.
  /// Config includes merged `meta` from tracks/{id}.meta.json for title/artist/thumbnail.
  Future<Map<String, dynamic>?> _lookupInGithubDB(
    String fileHash,
    String filename,
  ) async {
    Future<Map<String, dynamic>?> _fetchMeta(String trackId) async {
      try {
        final metaUrl = '$_dbBase/lyrics-db/tracks/$trackId.meta.json';
        final metaResp = await http
            .get(Uri.parse(metaUrl))
            .timeout(const Duration(seconds: 8));
        if (metaResp.statusCode == 200) {
          return jsonDecode(metaResp.body) as Map<String, dynamic>;
        }
      } catch (_) {}
      return null;
    }

    Map<String, dynamic> _mergeMeta(
        Map<String, dynamic> config, Map<String, dynamic>? trackMeta) {
      if (trackMeta == null) return config;
      // Build a meta map from the track meta file fields that clients expect.
      final merged = Map<String, dynamic>.from(config);
      merged['meta'] = {
        'title': trackMeta['title'] ?? trackMeta['track_title'] ?? '',
        'trackTitle': trackMeta['track_title'] ?? trackMeta['title'] ?? '',
        'track_title': trackMeta['track_title'] ?? trackMeta['title'] ?? '',
        'artist': trackMeta['artist'] ?? '',
        'thumbnail': trackMeta['thumbnail'] ?? '',
        'track_url': trackMeta['track_url'] ?? '',
      };
      return merged;
    }

    try {
      // 1. Try by file hash in track files (direct URL guess)
      final configUrl = '$_dbBase/lyrics-db/tracks/$fileHash.json';
      try {
        final configResp = await http
            .get(Uri.parse(configUrl))
            .timeout(const Duration(seconds: 8));
        if (configResp.statusCode == 200) {
          final config = jsonDecode(configResp.body) as Map<String, dynamic>;
          final trackMeta = await _fetchMeta(fileHash);
          return {
            'config': _mergeMeta(config, trackMeta),
            'trackId': fileHash,
          };
        }
      } catch (_) {
        // 404 or network error — try next
      }

      // 2. Search index by filename match
      final indexUrl = '$_dbBase/lyrics-db/index.json';
      final indexResp = await http
          .get(Uri.parse(indexUrl))
          .timeout(const Duration(seconds: 10));
      if (indexResp.statusCode != 200) return null;

      final index = jsonDecode(indexResp.body) as Map<String, dynamic>;
      final tracks = index['tracks'] as List? ?? [];
      final cleanName =
          filename.replaceAll(RegExp(r'\.[^.]+$'), '').toLowerCase();

      for (final track in tracks) {
        if (track is! Map) continue;
        final trackTitle = (track['title'] ?? '').toString().toLowerCase();
        if (trackTitle.contains(cleanName) || cleanName.contains(trackTitle)) {
          final file = track['file'] as String?;
          if (file != null) {
            final trackId = file.split('/').last.replaceAll('.json', '');
            final configUrl = '$_dbBase/lyrics-db/$file';
            final configResp = await http
                .get(Uri.parse(configUrl))
                .timeout(const Duration(seconds: 8));
            if (configResp.statusCode == 200) {
              final config =
                  jsonDecode(configResp.body) as Map<String, dynamic>;
              // Use index record for metadata fallback, then try meta.json.
              final indexMeta = <String, dynamic>{
                'title': track['title'] ?? '',
                'track_title': track['title'] ?? '',
                'artist': track['artist'] ?? '',
                'thumbnail': track['thumbnail'] ?? '',
              };
              final trackMeta = await _fetchMeta(trackId) ?? indexMeta;
              return {
                'config': _mergeMeta(config, trackMeta),
                'trackId': trackId,
              };
            }
          }
        }
      }
    } catch (e) {
      print('[DB-LOOKUP] Failed: $e');
    }
    return null;
  }

  /// Returns a File in the cache directory for local track storage.
  Future<File> _cachePath(String name) async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/$name.json');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Chromic Haptic'),
        backgroundColor: const Color(0xFF0A0A12),
        actions: [
          IconButton(
            icon: const Icon(Icons.info_outline, color: Colors.white38),
            tooltip: 'About & Privacy',
            onPressed: () => _showAboutDialog(),
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            TextField(
              controller: _urlController,
              style: const TextStyle(color: Colors.white, fontSize: 18),
              decoration: InputDecoration(
                hintText: 'SoundCloud URL',
                hintStyle: const TextStyle(color: Colors.white24),
                filled: true,
                fillColor: const Color(0xFF1A1A2E),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
                suffixIcon: _loading
                    ? Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              _loadingMessage,
                              style: const TextStyle(
                                  color: Colors.white38, fontSize: 12),
                            ),
                            const SizedBox(width: 8),
                            const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                          ],
                        ),
                      )
                    : IconButton(
                        icon: const Icon(Icons.play_arrow,
                            color: Color(0xFF4CAF50)),
                        onPressed: _loading
                            ? null
                            : () => _loadFromUrl(_urlController.text),
                      ),
              ),
              onSubmitted: _loading ? null : _loadFromUrl,
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                icon: const Icon(Icons.upload_file, size: 18),
                label: const Text('Upload audio file'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: const Color(0xFF4CAF50),
                  side: const BorderSide(color: Color(0xFF4CAF50)),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                onPressed: _loading ? null : _loadFromFile,
              ),
            ),
            // ── Upload progress banner (survives navigation, app lifecycle) ──
            if (_uploadStatus != null && _uploadStatus!.phase != 'done')
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: _UploadBanner(
                  status: _uploadStatus!,
                  onDismiss: () => setState(() => _uploadStatus = null),
                ),
              ),
            const SizedBox(height: 32),
            if (_localTracks.isNotEmpty || _history.isNotEmpty)
              Expanded(
                child: ListView(
                  children: [
                    if (_localTracks.isNotEmpty) ...[
                      const Padding(
                        padding: EdgeInsets.only(left: 16, bottom: 4),
                        child: Text('Cached tracks',
                            style:
                                TextStyle(color: Colors.white38, fontSize: 14)),
                      ),
                      ..._localTracks.map((t) => ListTile(
                            dense: true,
                            leading: const Icon(Icons.music_note,
                                color: Colors.white38, size: 20),
                            title: Text(t,
                                style: const TextStyle(
                                    color: Colors.white70, fontSize: 14)),
                            onTap: () => _openLocalTrack(t),
                          )),
                    ],
                    if (_history.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      const Padding(
                        padding: EdgeInsets.only(left: 16, bottom: 4),
                        child: Text('History',
                            style:
                                TextStyle(color: Colors.white38, fontSize: 14)),
                      ),
                      ..._history.map((h) {
                        final url = h['url'] as String;
                        final title = (h['title'] as String?) ?? url;
                        final artist = (h['artist'] as String?) ?? '';
                        final thumbnail = (h['thumbnail'] as String?) ?? '';
                        final dateStr = (h['date'] as String?) ?? '';
                        return ListTile(
                          dense: true,
                          leading:
                              thumbnailImage(thumbnail, width: 40, height: 40),
                          title: Text(title,
                              style: const TextStyle(
                                  color: Colors.white70, fontSize: 14)),
                          subtitle: Text(
                              artist.isNotEmpty
                                  ? artist
                                  : dateStr.length >= 16
                                      ? dateStr
                                          .substring(0, 16)
                                          .replaceAll('T', ' ')
                                      : '',
                              style: const TextStyle(
                                  color: Colors.white24, fontSize: 10)),
                          onTap: () => _loadFromHistoryEntry(url),
                        );
                      }),
                    ],
                  ],
                ),
              ),
            if (_localTracks.isEmpty && _history.isEmpty)
              Expanded(
                child: Center(
                  child: Padding(
                    padding: const EdgeInsets.all(32),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Icon(Icons.vibration,
                            size: 72, color: Colors.white10),
                        const SizedBox(height: 20),
                        Text('Feel the music.\nLiterally.',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                                color: Colors.white54,
                                fontSize: 22,
                                fontWeight: FontWeight.w600)),
                        const SizedBox(height: 8),
                        Text(
                            'Paste a SoundCloud link to convert music into tactile vibrations.',
                            textAlign: TextAlign.center,
                            style:
                                TextStyle(color: Colors.white30, fontSize: 14)),
                        const SizedBox(height: 28),
                        OutlinedButton.icon(
                          icon: const Icon(Icons.paste, size: 18),
                          label: const Text('Paste SoundCloud link'),
                          onPressed: _pasteFromClipboard,
                          style: OutlinedButton.styleFrom(
                            foregroundColor: const Color(0xFF4CAF50),
                            side: const BorderSide(color: Color(0xFF4CAF50)),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    _uploadSub?.cancel();
    _urlController.dispose();
    super.dispose();
  }
}

// ── Upload progress banner (glass-morphism, survives navigation) ──

class _UploadBanner extends StatelessWidget {
  final UploadStatus status;
  final VoidCallback onDismiss;

  const _UploadBanner({required this.status, required this.onDismiss});

  @override
  Widget build(BuildContext context) {
    final isError = status.phase == 'error';
    final isDone = status.phase == 'done';
    final isUploading = status.phase == 'uploading';
    final accent = isError ? Colors.redAccent : const Color(0xFF4CAF50);

    return AnimatedContainer(
      duration: const Duration(milliseconds: 300),
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            accent.withValues(alpha: 0.15),
            accent.withValues(alpha: 0.05),
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: accent.withValues(alpha: 0.25)),
        boxShadow: [
          BoxShadow(
            color: accent.withValues(alpha: 0.08),
            blurRadius: 16,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Header row: icon + filename + elapsed + cancel ──
          Row(
            children: [
              _PhaseIcon(phase: status.phase, accent: accent),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (status.filename.isNotEmpty)
                      Text(
                        status.filename,
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.9),
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    Text(
                      status.message,
                      style: TextStyle(
                        color: accent,
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ),
              if (!isDone && !isError && !isUploading)
                Text(
                  status.elapsedText,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.4),
                    fontSize: 11,
                  ),
                ),
              // Always show cancel/dismiss
              GestureDetector(
                onTap: () {
                  UploadService.instance.cancel(status.key);
                  onDismiss();
                },
                child: Padding(
                  padding: const EdgeInsets.only(left: 8),
                  child: Icon(
                    isError ? Icons.close : Icons.cancel_outlined,
                    color: Colors.white.withValues(alpha: 0.35),
                    size: 18,
                  ),
                ),
              ),
            ],
          ),
          // ── Progress bar (indeterminate shimmer) ──
          if (!isDone && !isError) ...[
            const SizedBox(height: 10),
            _ShimmerBar(accent: accent),
          ],
          // ── Error actions ──
          if (isError) ...[
            const SizedBox(height: 8),
            Text(
              'Tap to dismiss. Re-upload the file to try again.',
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.3),
                fontSize: 10,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Animated phase icon — cloud → spinner → check → error.
class _PhaseIcon extends StatelessWidget {
  final String phase;
  final Color accent;

  const _PhaseIcon({required this.phase, required this.accent});

  @override
  Widget build(BuildContext context) {
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 300),
      child: SizedBox(
        key: ValueKey(phase),
        width: 22,
        height: 22,
        child: switch (phase) {
          'uploading' =>
            Icon(Icons.cloud_upload_outlined, color: accent, size: 20),
          'processing' =>
            CircularProgressIndicator(strokeWidth: 2.5, color: accent),
          'done' => Icon(Icons.check_circle, color: accent, size: 20),
          _ => Icon(Icons.error_outline, color: accent, size: 20),
        },
      ),
    );
  }
}

/// Indeterminate shimmer progress bar.
class _ShimmerBar extends StatefulWidget {
  final Color accent;

  const _ShimmerBar({required this.accent});

  @override
  State<_ShimmerBar> createState() => _ShimmerBarState();
}

class _ShimmerBarState extends State<_ShimmerBar>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1800),
    )..repeat();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (_, __) {
        return Container(
          height: 3,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(2),
            color: Colors.white.withValues(alpha: 0.06),
          ),
          child: Align(
            alignment: Alignment.centerLeft,
            child: FractionallySizedBox(
              widthFactor: 0.35,
              alignment: Alignment(
                -1 + (_ctrl.value * 2.5),
                0,
              ),
              child: Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(2),
                  gradient: LinearGradient(
                    colors: [
                      widget.accent.withValues(alpha: 0),
                      widget.accent.withValues(alpha: 0.6),
                      widget.accent.withValues(alpha: 0),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// PLAYER SCREEN — lyrics + haptics + audio
// ═══════════════════════════════════════════════════════════════════════════

class PlayerScreen extends StatefulWidget {
  final Map<String, dynamic> trackData;
  final String sourceTitle;
  final String? trackUrl;

  const PlayerScreen({
    super.key,
    required this.trackData,
    required this.sourceTitle,
    this.trackUrl,
  });

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen>
    with SingleTickerProviderStateMixin {
  final AudioPlayer _audio = AudioPlayer();
  late Ticker _ticker;
  double _time = 0;
  double _duration = 0;
  bool _playing = false;
  bool _audioReady = false;
  late List<LyricLine> _lyrics;

  double _lastFrameSec = 0.0;

  // ── Per-line animated properties (match Troika e._cOp/_cOy/_scrollLag) ──
  final Map<int, double> _cOp = {};
  final Map<int, double> _cOy = {};
  final Map<int, double> _scrollLag = {};
  final Map<int, double> _prevTOp = {};
  final Map<int, double> _prevTOy = {};

  Map<String, dynamic>? _haptics;
  HapticEngine? _hapticEngine;
  List<HapticEvent> _hapticEvents = [];
  bool _showHapticPanel = true;
  String _titleText = '';
  String _artistText = '';
  String _thumbnailUrl = '';
  HapticMode _hapticMode = HapticMode.both;
  HapticDeviceCaps _deviceCaps = const HapticDeviceCaps();

  // Track if playback has ever started (for cue dot animation state).
  bool _hasPlayed = false;

  // ── Troika scroll system (velocity for parallax) ──
  double _scrollVelocity = 0.0; // px/s (for parallax lag)
  int _prevActiveIdx = 0;

  // ── Smooth scroll lerp (GSAP-style exponential decay) ──
  double _smoothSy = 0.0;
  double _targetSy = 0.0;

  // ── Manual scroll state ──
  double _manualScrollOffset = 0.0;
  double _scrollDecayTimer = 0.0;
  static const double _scrollDecayDuration = 2.0; // 2s delay before auto-snap
  final GlobalKey _lyricsAreaKey = GlobalKey();

  // ── Manual scroll bounds (reported by LyricPainter each frame) ──
  double _minManualScroll = double.negativeInfinity;
  double _maxManualScroll = double.infinity;

  // ── Manual scroll mode (user drag) ──
  bool _isManualScrolling = false;

  // ── Bloom shader ──
  ui.FragmentProgram? _glowProgram;
  ui.FragmentProgram? _bloomProgram;

  /// Precise clamp using per-frame bounds reported by [LyricPainter.onLayout].
  void _clampScrollOffset() {
    if (_lyrics.isEmpty) {
      _manualScrollOffset = 0.0;
      return;
    }
    _manualScrollOffset =
        _manualScrollOffset.clamp(_minManualScroll, _maxManualScroll);
  }

  static const _playerColor = Color(0xFF4CAF50);
  static const _downloadAudioUrl =
      'https://romaniv1437--chromic-trainer-split-v3-download-audio.modal.run';

  @override
  void initState() {
    super.initState();
    _parseData(widget.trackData);
    _loadGlowShader();
    _ticker = createTicker(_onTick);
    // Start ticker immediately so scroll positions the active line before first play.
    _ticker.start();
    _initAudio();
    _initDeviceCaps();
  }

  Future<void> _initDeviceCaps() async {
    _deviceCaps = await Vibration.getDeviceCaps();
    debugPrint('[HAPTIC] Device: res=${_deviceCaps.resonantFrequencyHz}Hz '
        'Q=${_deviceCaps.qFactor} amp=${_deviceCaps.hasAmplitudeControl}');
  }

  void _parseData(Map<String, dynamic> d) {
    // Clear Troika animation state on track change.
    _lastFrameSec = 0.0;
    _hasPlayed = false;
    _cOp.clear();
    _cOy.clear();
    _scrollLag.clear();
    _prevTOp.clear();
    _prevTOy.clear();
    _prevActiveIdx = 0;
    _manualScrollOffset = 0.0;
    _scrollDecayTimer = 0.0;
    _isManualScrolling = false;
    _scrollVelocity = 0.0;
    _smoothSy = 0.0;
    _targetSy = 0.0;

    _titleText = (d['meta'] != null && d['meta'] is Map)
        ? ((d['meta'] as Map)['title']?.toString() ??
            (d['meta'] as Map)['trackTitle']?.toString() ??
            widget.sourceTitle)
        : widget.sourceTitle;

    _artistText = (d['meta'] != null && d['meta'] is Map)
        ? ((d['meta'] as Map)['artist']?.toString() ?? '')
        : '';

    _thumbnailUrl = (d['meta'] != null && d['meta'] is Map)
        ? ((d['meta'] as Map)['thumbnail']?.toString() ?? '')
        : '';

    _lyrics = (d['lines'] as List<dynamic>?)
            ?.map((l) => LyricLine.fromJson(l as Map<String, dynamic>))
            .toList() ??
        [];

    _haptics = d['haptics'] as Map<String, dynamic>?;

    if (_lyrics.isNotEmpty) {
      final lastLine = _lyrics.last;
      final lastWordEnd =
          lastLine.words.isNotEmpty ? lastLine.words.last.end : null;
      _duration = (lastWordEnd ?? lastLine.end) ?? 0.0;
    } else if (_haptics != null &&
        _haptics!['meta'] != null &&
        _haptics!['meta']['duration_s'] != null) {
      _duration = (_haptics!['meta']['duration_s'] as num?)?.toDouble() ?? 0.0;
    }

    if (_haptics != null && _haptics!['events'] != null) {
      final rawEvents = _haptics!['events'] as List<dynamic>;
      final schemaVer = (_haptics!['schema_version'] as int?) ?? 1;
      _hapticEvents = rawEvents
          .map((e) => schemaVer >= 3
              ? HapticEvent.fromJsonV3(e as Map<String, dynamic>)
              : HapticEvent.fromJson(e as Map<String, dynamic>))
          .toList();
      _hapticEvents.sort((a, b) => a.time.compareTo(b.time));
      _hapticEngine = HapticEngine(
        events: _hapticEvents,
        getPlayerTime: () => _time,
        mode: _hapticMode,
        deviceCaps: _deviceCaps,
      );
    }
  }

  Future<void> _initAudio() async {
    try {
      // ══ Local file path (file upload, no Modal audio) ══
      final localPath = widget.trackData['_localAudioPath'] as String?;
      if (localPath != null && localPath.isNotEmpty) {
        final file = File(localPath);
        if (await file.exists()) {
          print('[AUDIO] Local file: $localPath');
          await _audio.setFilePath(localPath);
          _audioReady = true;
          if (mounted) setState(() {});
          return;
        }
        print('[AUDIO] Local file missing, falling back: $localPath');
      }

      final audioUrl = widget.trackData['audio_url'] as String?;
      if (audioUrl != null && audioUrl.isNotEmpty) {
        await _audio.setUrl(audioUrl);
        _audioReady = true;
        if (mounted) setState(() {});
        return;
      }
      // No audio_url — download via Modal
      final sourcePath = widget.trackData['_sourcePath'] as String?;
      final downloadUrl = widget.trackUrl ?? sourcePath;
      if (downloadUrl != null && downloadUrl.isNotEmpty) {
        await _downloadAndCacheAudio(downloadUrl);
      }
    } catch (e) {
      print('[AUDIO] Init failed: $e');
    }
  }

  Future<void> _downloadAndCacheAudio(String url) async {
    try {
      // Mobile/desktop: check cache first, then download
      final dir = await getApplicationDocumentsDirectory();
      final audioDir = Directory('${dir.path}/audio');
      final slug = url.replaceAll(RegExp(r'[^\w]'), '_').substring(0, 40);
      final file = File('${audioDir.path}/$slug.m4a');

      if (await file.exists()) {
        print('[AUDIO] Cached: ${file.path}');
        await _audio.setFilePath(file.path);
        _audioReady = true;
        if (mounted) setState(() {});
        return;
      }

      print('[AUDIO] Downloading from: $url');
      final response = await http.post(Uri.parse(_downloadAudioUrl),
          body: jsonEncode({'track_url': url}),
          headers: {
            'Content-Type': 'application/json',
            'x-chromic-token': 'super-secret-chromic-string-1437',
          }).timeout(const Duration(minutes: 3));

      if (response.statusCode != 200) {
        print('[AUDIO] Download failed: ${response.statusCode}');
        return;
      }

      final bytes = response.bodyBytes;
      print('[AUDIO] Downloaded ${bytes.length} bytes');

      await audioDir.create(recursive: true);
      await file.writeAsBytes(bytes);
      print('[AUDIO] Saved: ${file.path}');

      await _audio.setFilePath(file.path);
      _audioReady = true;
      if (mounted) setState(() {});
    } catch (e) {
      print('[AUDIO] Download error: $e');
    }
  }

  // Wall-clock time for dt when paused (audio pos is constant).
  double _wallSec = 0;

  void _onTick(Duration elapsed) {
    final wallNow = elapsed.inMicroseconds / 1000000.0;
    double pos = _audio.position.inMilliseconds / 1000.0;

    if (_playing) {
      if (pos > _duration && _duration > 0) {
        _pause();
        return;
      }
      _time = pos.isNaN || pos.isInfinite ? 0.0 : math.max(0.0, pos);
    } else {
      // Paused: use stored position so lyrics track correct line.
      // Use wall-clock dt so decay/scrolling still animate.
      pos = _time;
    }

    final dt = _playing
        ? (pos - _lastFrameSec).clamp(0.0, 0.2)
        : (wallNow - _wallSec).clamp(0.0, 0.2);
    _lastFrameSec = pos;
    _wallSec = wallNow;
    if (_lyrics.isNotEmpty) {
      _updateLineAnimations(dt, pos);
      _updateScroll(dt, pos);
      _updateScrollPosition(dt);
    }

    // ── Manual scroll 2-second decay timer ──
    if (_scrollDecayTimer > 0) {
      _scrollDecayTimer -= dt.clamp(0.0, 0.1);
      if (_scrollDecayTimer <= 0) {
        _scrollDecayTimer = 0;
        _isManualScrolling = false;
        // ── SNAP: after 2s idle, snap to auto-scroll position ──
        _manualScrollOffset = 0.0;
        if (_lyrics.isNotEmpty) {
          final ai = LyricPainter.findActiveIdx(_lyrics, pos);
          for (int i = 0; i < _lyrics.length; i++) {
            final state = LyricPainter.stateForLine(_lyrics, i, ai, pos);
            _cOp[i] = LyricPainter.stateOpacity(i, ai, state);
            _cOy[i] = 0.0;
            _scrollLag[i] = 0.0;
          }
          _scrollVelocity = 0.0;
        }
      }
    }

    setState(() {});
  }

  // ── Troika Layer 2+3: per-line opacity/offset + fluid parallax ──
  void _updateLineAnimations(double dt, double pos) {
    if (_lyrics.isEmpty) return;

    final ai = LyricPainter.findActiveIdx(_lyrics, pos);
    final clampedDt = dt.clamp(0.0, 0.1);

    double _targetOp(int li, int sai) {
      if (_manualScrollOffset.abs() > 0.5) return li == sai ? 1.0 : 0.7;
      // Adlib lines use adlib-specific opacities (Troika: adlibOn/Off/Hid)
      final state = LyricPainter.stateForLine(_lyrics, li, sai, pos);
      if (state == LineState.adlib) {
        return LyricPainter.stateOpacity(li, sai, state);
      }
      if (li == sai) return 1.0;
      if (li < sai) return 0.0;
      final d = li - sai;
      if (d == 1) return 0.55;
      if (d == 2) return 0.30;
      if (d == 3) return 0.14;
      if (d == 4) return 0.07;
      return 0.04;
    }

    double _targetOy(int li, int sai) {
      if (_manualScrollOffset.abs() > 0.5) return 0;
      if (li <= sai) return 0;
      final d = li - sai;
      final fh = 28.0 * 1.5; // ~42px
      if (d == 1) return -0.15 * fh; // ~6px
      if (d == 2) return -0.30 * fh; // ~12px
      return -0.45 * fh; // ~18px
    }

    for (int i = 0; i < _lyrics.length; i++) {
      _cOp[i] ??= _targetOp(i, ai);
      _cOy[i] ??= 0.0;
      _scrollLag[i] ??= 0.0;
      _prevTOp[i] ??= _cOp[i]!;
      _prevTOy[i] ??= 0.0;

      final newTOp = _targetOp(i, ai);
      final newTOy = _targetOy(i, ai);

      final isPast = i < ai;
      final isActive = i == ai;
      final d = (i - ai).abs();

      double opLerpSpeed;
      if (isPast) {
        opLerpSpeed = 12.0;
      } else if (isActive) {
        opLerpSpeed = 8.0;
      } else {
        final dur = 0.35 + d * 0.18;
        opLerpSpeed = 3.0 / dur;
      }

      final fOp = 1 - math.exp(-opLerpSpeed * clampedDt);
      _cOp[i] = _cOp[i]! + (newTOp - _cOp[i]!) * fOp;
      _cOy[i] =
          _cOy[i]! + (newTOy - _cOy[i]!) * (1 - math.exp(-5.0 * clampedDt));

      if ((_cOp[i]! - newTOp).abs() < 0.003) _cOp[i] = newTOp;
      if ((_cOy[i]! - newTOy).abs() < 0.001) _cOy[i] = newTOy;
      _prevTOp[i] = newTOp;
      _prevTOy[i] = newTOy;

      // No per-iteration velocity calc here — _scrollVelocity updated in _updateScroll
    }

    // ── Per-line parallax lag (after all _cOp/_cOy updates) ──

    for (int i = 0; i < _lyrics.length; i++) {
      _scrollLag[i] ??= 0.0;
      final dist = i - ai;
      if (dist > 0 && _manualScrollOffset.abs() < 0.5) {
        // Future line: lag behind during auto-scroll
        final depth = math.min(2.4, dist.toDouble());
        final velScale = _isManualScrolling ? 0.0048 : 0.004;
        final targetLag = _scrollVelocity * depth * velScale;
        final stiffness = _isManualScrolling ? 11.0 : 12.0;
        final lagLerp = math.min(1.0, stiffness * clampedDt);
        _scrollLag[i] = _scrollLag[i]! + (targetLag - _scrollLag[i]!) * lagLerp;
      } else {
        // Past/same line or manual scroll: decay lag to 0
        if ((_scrollLag[i] ?? 0.0).abs() > 0.1) {
          final relaxMul = dist > 0 ? 1.0 : 1.7;
          final stiffness = _isManualScrolling ? 11.0 : 12.0;
          final lagLerp = math.min(1.0, stiffness * relaxMul * clampedDt);
          _scrollLag[i] = _scrollLag[i]! + (0.0 - _scrollLag[i]!) * lagLerp;
        } else {
          _scrollLag[i] = 0.0;
        }
      }
    }
  }

  void _updateScrollPosition(double dt) {
    // During manual scroll, snap instantly (user is dragging).
    if (_isManualScrolling) {
      _smoothSy = _targetSy;
      return;
    }
    // Exponential lerp toward target — frame-rate independent.
    // Speed 10.0 = reaches 95% in ~0.3s (smooth but responsive).
    final speed = 10.0;
    final lerp = math.min(1.0, 1 - math.exp(-speed * dt.clamp(0.0, 0.05)));
    _smoothSy += (_targetSy - _smoothSy) * lerp;

    if ((_smoothSy - _targetSy).abs() < 0.05) _smoothSy = _targetSy;
  }

  void _updateScroll(double dt, double pos) {
    // Position handled by LyricPainter internally (sy = height*0.15 - activeTopOffset - manualScrollOffset).
    // This method only computes _scrollVelocity for parallax.
    if (_lyrics.isEmpty) return;

    final ai = LyricPainter.findActiveIdx(_lyrics, pos);
    final avgLineH = 28.0 * 1.556 + 28.0 * 0.4; // ~60px
    final prevAi = _prevActiveIdx;
    _prevActiveIdx = ai;

    if (dt > 0.001) {
      // Velocity from activeIdx change (lines/sec), then convert to px/sec
      final instVelLines = (ai - prevAi) / dt; // lines/sec
      final instVelPx = instVelLines * avgLineH; // px/sec
      _scrollVelocity += (instVelPx - _scrollVelocity) * 0.35;
    }
  }

  void _play() {
    if (!_audioReady) {
      _showSnack('⏳ Downloading audio...');
      return;
    }
    _hasPlayed = true;
    setState(() => _playing = true);
    _audio.play();
    _hapticEngine?.start();
    _ticker.start();
  }

  void _pause() {
    setState(() => _playing = false);
    _audio.pause();
    _hapticEngine?.stop();
    // Keep ticker running — scroll still tracks active line when paused.
  }

  void _seekTo(double sec) {
    if (_audioReady) {
      _audio.seek(Duration(milliseconds: (sec * 1000).round()));
    }
    // Keep animated state — let lerp machinery handle smooth transition
    _lastFrameSec = sec;
    // Reset parallax lag instantly (same as return-from-manual snap)
    _scrollLag.forEach((k, v) => _scrollLag[k] = 0.0);
    // Reset manual scroll on seek
    _prevActiveIdx = LyricPainter.findActiveIdx(_lyrics, sec);
    _manualScrollOffset = 0.0;
    _scrollDecayTimer = 0.0;
    _isManualScrolling = false;
    _scrollVelocity = 0.0;
    setState(() => _time = sec);
    _hapticEngine?.seekTo(sec);
  }

  String _fmtTime(double s) {
    if (s.isNaN || s.isInfinite || s < 0) s = 0;
    final m = (s ~/ 60);
    final sec = (s % 60).toStringAsFixed(1).padLeft(4, '0');
    return '$m:$sec';
  }

  void _showSnack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(msg), duration: const Duration(seconds: 2)));
  }

  double _textMaxWidthRatio(BuildContext context) {
    final width = MediaQuery.of(context).size.width;
    // Tablet (width >= 600dp): narrower text to leave room for other UI
    // Phone: wider text fills the screen better
    return width >= 600 ? 0.75 : 0.85;
  }

  IconData _getHapticModeIcon() {
    switch (_hapticMode) {
      case HapticMode.both:
        return Icons.vibration;
      case HapticMode.beat:
        return Icons.music_note;
      case HapticMode.instrumental:
        return Icons.piano;
      case HapticMode.word:
        return Icons.text_fields;
      case HapticMode.full:
        return Icons.surround_sound;
    }
  }

  String _getHapticModeLabel() {
    switch (_hapticMode) {
      case HapticMode.both:
        return 'Beat + Word';
      case HapticMode.beat:
        return 'Beat';
      case HapticMode.instrumental:
        return 'Instrumental';
      case HapticMode.word:
        return 'Word only';
      case HapticMode.full:
        return 'Full texture';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0A0A12),
      appBar: AppBar(
        title: Row(
          children: [
            if (_thumbnailUrl.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(right: 12),
                child: thumbnailImage(_thumbnailUrl, width: 40, height: 40),
              ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _titleText,
                    style: const TextStyle(fontSize: 16),
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (_artistText.isNotEmpty)
                    Text(
                      _artistText,
                      style:
                          const TextStyle(fontSize: 12, color: Colors.white54),
                      overflow: TextOverflow.ellipsis,
                    ),
                ],
              ),
            ),
          ],
        ),
        backgroundColor: const Color(0xFF0A0A12),
        actions: [
          if (_hapticEvents.isNotEmpty)
            IconButton(
              icon: Icon(
                _getHapticModeIcon(),
                color: _playerColor,
              ),
              tooltip: _getHapticModeLabel(),
              onPressed: () {
                setState(() {
                  switch (_hapticMode) {
                    case HapticMode.both:
                      _hapticMode = HapticMode.beat;
                      break;
                    case HapticMode.beat:
                      _hapticMode = HapticMode.instrumental;
                      break;
                    case HapticMode.instrumental:
                      _hapticMode = HapticMode.word;
                      break;
                    case HapticMode.word:
                      _hapticMode = HapticMode.full;
                      break;
                    case HapticMode.full:
                      _hapticMode = HapticMode.both;
                      break;
                  }
                  _hapticEngine?.setMode(_hapticMode);
                });
              },
            ),
          if (_hapticEvents.isNotEmpty)
            IconButton(
              icon: Icon(
                _showHapticPanel ? Icons.timeline : Icons.timeline_outlined,
                color: _playerColor,
              ),
              onPressed: () =>
                  setState(() => _showHapticPanel = !_showHapticPanel),
            ),
          if (_audioReady)
            const Padding(
              padding: EdgeInsets.only(right: 12),
              child: Icon(Icons.headphones, size: 18, color: Color(0xFF4CAF50)),
            ),
        ],
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_showHapticPanel && _hapticEvents.isNotEmpty)
            SizedBox(
              height: 120,
              child: HapticTimeline(
                events: _hapticEvents,
                mode: _hapticMode,
                playerTime: _time,
                totalDuration: _duration,
              ),
            ),
          Expanded(
            child: ClipRect(
              child: SafeArea(
                child: Listener(
                  // Mouse wheel / trackpad scroll on desktop web (matches LyricsRenderer.handleWheel).
                  // PointerScrollEvent type doesn't compile on web target → use dynamic for scrollDelta.
                  onPointerSignal: (event) {
                    try {
                      final delta = (event as dynamic).scrollDelta;
                      if (delta != null && delta is Offset && delta.dy != 0) {
                        _isManualScrolling = true;
                        _manualScrollOffset -= delta.dy;
                        _clampScrollOffset();
                        setState(() {});
                      }
                    } catch (_) {}
                  },
                  child: GestureDetector(
                    key: _lyricsAreaKey,
                    // Click-to-seek: tap on a word → seek to its time.
                    // Tap elsewhere → toggle play/pause.
                    onTapUp: (details) {
                      final renderBox = _lyricsAreaKey.currentContext
                          ?.findRenderObject() as RenderBox?;
                      final size = renderBox?.size;
                      if (size == null) return;
                      final seekTime = LyricPainter.hitTestWord(
                        size: size,
                        lines: _lyrics,
                        tapPos: details.localPosition,
                        playerTime: _time,
                        textMaxWidthRatio: _textMaxWidthRatio(context),
                        smoothedOpacities: _cOp,
                        manualScrollOffset: _manualScrollOffset,
                      );
                      if (seekTime != null) {
                        _seekTo(seekTime);
                      } else {
                        _playing ? _pause() : _play();
                      }
                    },
                    // Manual vertical drag → scroll through lyrics
                    onVerticalDragStart: (_) {
                      _scrollDecayTimer =
                          0.0; // Cancel pending snap on re-touch
                      _isManualScrolling = true;
                    },
                    onVerticalDragUpdate: (details) {
                      _scrollDecayTimer =
                          0.0; // Keep timer frozen while dragging
                      _manualScrollOffset -= details.delta.dy;
                      _clampScrollOffset();
                      setState(() {});
                    },
                    onVerticalDragEnd: (_) {
                      _scrollDecayTimer =
                          _scrollDecayDuration; // Start 2s timer
                    },
                    onVerticalDragCancel: () {
                      _scrollDecayTimer =
                          _scrollDecayDuration; // Start 2s timer
                    },
                    child: Stack(
                      children: [
                        // Sharp text — base render, gestures, hit-test
                        CustomPaint(
                          size: Size.infinite,
                          painter: LyricPainter(
                            lines: _lyrics,
                            playerTime: _time,
                            cOp: _cOp,
                            cOy: _cOy,
                            scrollLag: _scrollLag,
                            textMaxWidthRatio: _textMaxWidthRatio(context),
                            manualScrollOffset: _manualScrollOffset,
                            isScrolling: _isManualScrolling,
                            smoothSy: _smoothSy,
                            trackStarted: _hasPlayed,
                            glowProgram: _glowProgram,
                            onLayout: (targetSy, minManual, maxManual) {
                              _targetSy = targetSy;
                              _minManualScroll = minManual;
                              _maxManualScroll = maxManual;
                            },
                          ),
                        ),

                        // Bloom overlay — multi-scale Gaussian blur for stretch words
                        if (_bloomProgram != null)
                          LyricBloomOverlay(
                            lines: _lyrics,
                            playerTime: _time,
                            bloomProgram: _bloomProgram!,
                            cOp: _cOp,
                            textMaxWidthRatio: _textMaxWidthRatio(context),
                            manualScrollOffset: _manualScrollOffset,
                            smoothSy: _smoothSy,
                            sigma: 4.0, // tighter blur → brighter core glow
                            strength: 6.0, // non-HDR needs extra push
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
          // Progress bar — Stack avoids Row layout issue where left child vanishes after 1st frame
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: SizedBox(
              height: 48,
              child: Stack(
                children: [
                  // Slider fills full width
                  Positioned.fill(
                    child: SliderTheme(
                      data: SliderTheme.of(context).copyWith(
                        activeTrackColor: _playerColor,
                        inactiveTrackColor: Colors.white12,
                        thumbColor: _playerColor,
                        overlayColor: _playerColor.withValues(alpha: 0.2),
                      ),
                      child: Slider(
                        value: _time.clamp(0, _duration > 0 ? _duration : 1),
                        max: _duration > 0 ? _duration : 1,
                        onChanged: _seekTo,
                      ),
                    ),
                  ),
                  // Left time label (overlaid on slider track)
                  Positioned(
                    left: 0,
                    top: 0,
                    bottom: 0,
                    child: Center(
                      child: Text(
                        _fmtTime(_time),
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 12,
                        ),
                      ),
                    ),
                  ),
                  // Right time label (overlaid on slider track)
                  Positioned(
                    right: 0,
                    top: 0,
                    bottom: 0,
                    child: Center(
                      child: Text(
                        _fmtTime(_duration),
                        style: const TextStyle(
                          color: Colors.white38,
                          fontSize: 12,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          // Play/Pause button
          IconButton(
            iconSize: 48,
            icon: _audioReady
                ? Icon(
                    _playing
                        ? Icons.pause_circle_filled
                        : Icons.play_circle_filled,
                    color: _playerColor,
                  )
                : const SizedBox(
                    width: 36,
                    height: 36,
                    child: CircularProgressIndicator(
                      strokeWidth: 2.5,
                      color: Color(0xFF4CAF50),
                    ),
                  ),
            onPressed: _audioReady ? () => _playing ? _pause() : _play() : null,
          ),
          const SizedBox(height: 32),
        ],
      ),
    );
  }

  Future<void> _loadGlowShader() async {
    try {
      _glowProgram =
          await ui.FragmentProgram.fromAsset('shaders/char_glow.frag');
      if (mounted) setState(() {});
    } catch (e) {
      debugPrint('[GLOW_SHADER] ❌ $e');
    }
    try {
      _bloomProgram = await ui.FragmentProgram.fromAsset('shaders/bloom.frag');
      if (mounted) setState(() {});
    } catch (e) {
      debugPrint('[BLOOM_SHADER] ❌ $e');
    }
  }

  @override
  void dispose() {
    _hapticEngine?.stop();
    _ticker.dispose();
    _audio.dispose();
    super.dispose();
  }
}
