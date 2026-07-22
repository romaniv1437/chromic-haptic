import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Haptic mode selector — which event types to fire.
enum HapticMode {
  /// Instrumental events (kick, snare, hihat, crash, bass, guitar, piano, arpeggio, etc).
  beat,

  /// Only word events (word_pulse, word_sustain).
  word,

  /// Non-vocal events only (everything except word_pulse/word_sustain).
  instrumental,

  /// All events.
  both,

  /// Full texture: all instrument + vocal events (v4).
  full,
}

/// Haptic engine v4 — polls player position at 50Hz, fires unified event stream.
///
/// Events come from [HapticEvent.fromJsonV3] / [HapticEvent.fromJsonV4] —
/// a single merged array from `haptic.py` (already collision-merged + masking-cleaned).
///
/// On Android: fires oneShot(6-20ms) via MethodChannel.
/// On web: no-op (MethodChannel not available).
class HapticEngine {
  final List<HapticEvent> _allEvents;
  final double Function() getPlayerTime;
  Timer? _timer;
  int _nextIdx = 0;
  bool _running = false;

  /// Which event types to fire. Changed via [setMode].
  HapticMode _mode = HapticMode.both;

  /// Device haptic capabilities reported by Android.
  HapticDeviceCaps deviceCaps = const HapticDeviceCaps();

  HapticEngine({
    required List<HapticEvent> events,
    required this.getPlayerTime,
    HapticMode mode = HapticMode.both,
    this.deviceCaps = const HapticDeviceCaps(),
  }) : _allEvents = List.unmodifiable(events),
       _mode = mode;

  /// Set the haptic mode. Resets the event index to current time.
  void setMode(HapticMode mode) {
    if (_mode == mode) return;
    _mode = mode;
    // Re-seek to current position so we don't skip events.
    seekTo(getPlayerTime());
  }

  HapticMode get mode => _mode;

  void start() {
    if (_allEvents.isEmpty || _running) return;
    _nextIdx = 0;
    _running = true;
    // Poll at 50Hz (20ms) — sufficient for 6-35ms vibration pulses.
    _timer = Timer.periodic(const Duration(milliseconds: 20), (_) => _tick());
  }

  void _tick() {
    if (!_running) return;
    final now = getPlayerTime();
    while (_nextIdx < _allEvents.length && _allEvents[_nextIdx].time <= now) {
      final evt = _allEvents[_nextIdx];
      // Filter by mode: skip events that don't match.
      if (_shouldFire(evt)) {
        _fire(evt);

        // Double-fire: if next event is a different type and within 5ms, fire it too.
        if (_nextIdx + 1 < _allEvents.length) {
          final nextEvt = _allEvents[_nextIdx + 1];
          if (nextEvt.time - evt.time < 0.005 &&
              nextEvt.type != evt.type &&
              _shouldFire(nextEvt) &&
              nextEvt.time <= now) {
            // Schedule second fire after 2ms so both pulses are felt
            Timer(const Duration(milliseconds: 2), () {
              if (_running) _fire(nextEvt);
            });
            _nextIdx++; // skip the second event in the main loop
          }
        }
      }
      _nextIdx++;
    }
  }

  /// Returns true if this event should fire under the current [HapticMode].
  bool _shouldFire(HapticEvent evt) {
    switch (_mode) {
      case HapticMode.beat:
      case HapticMode.instrumental:
        return _isInstrumental(evt.type);
      case HapticMode.word:
        return evt.type == 'word_pulse' || evt.type == 'word_sustain';
      case HapticMode.both:
      case HapticMode.full:
        return true;
    }
  }

  /// Instrumental event types — all non-vocal events (percussion + melodic).
  bool _isInstrumental(String type) {
    switch (type) {
      case 'kick':
      case 'snare':
      case 'hihat':
      case 'crash':
      case 'beat': // legacy
      case 'bass_beat':
      case 'bass_slide':
      case 'bass_sustain':
      case 'piano_strike':
      case 'piano_sustain':
      case 'arpeggio':
      case 'guitar_strum':
      case 'guitar_pick':
      case 'guitar_slide':
      case 'guitar_mute':
      case 'synth_pad':
      case 'orchestral_hit':
      case 'texture_drone':
        return true;
      default:
        return false;
    }
  }

  /// Fire a single haptic event via native MethodChannel.
  ///
  /// Duration is capped at 20ms (Android native also caps it).
  /// Amplitude = intensity * typeBoost mapped to 1-255 range.
  Future<void> _fire(HapticEvent evt) async {
    try {
      final boost = _typeBoost(evt.type);
      final amp = (evt.intensity * boost * 255).round().clamp(1, 255);
      await Vibration.vibrate(
        duration: math.min(evt.durationMs, 20),
        amplitude: amp,
      );
    } catch (e) {
      debugPrint('[HAPTIC] fire failed: $e');
    }
  }

  /// Per-type intensity boost for tactile differentiation (v4 full texture).
  ///
  /// Boost values tuned so each instrument type feels distinct:
  ///   - Kick/bass = low-freq rumble (high boost)
  ///   - Snare/crash = sharp hit
  ///   - Hihat = light tickle
  ///   - Guitar strum = wide vibration
  ///   - Piano = clean key press
  ///   - Arpeggio = rapid tickle
  ///   - Synth pad = barely there
  ///   - Vocals = speech feel
  double _typeBoost(String type) {
    switch (type) {
      // Percussion
      case 'kick':
        return 2.0;
      case 'snare':
        return 1.7;
      case 'hihat':
        return 0.8;
      case 'crash':
        return 1.7;
      case 'beat': // legacy
        return 1.4;

      // Bass
      case 'bass_beat':
        return 1.8;
      case 'bass_slide':
        return 1.3;
      case 'bass_sustain':
        return 1.0;

      // Keys
      case 'piano_strike':
        return 1.5;
      case 'piano_sustain':
        return 1.0;
      case 'arpeggio':
        return 1.2;

      // Guitar
      case 'guitar_strum':
        return 1.6;
      case 'guitar_pick':
        return 1.4;
      case 'guitar_slide':
        return 1.3;
      case 'guitar_mute':
        return 0.9;

      // Texture (other)
      case 'synth_pad':
        return 0.6;
      case 'orchestral_hit':
        return 1.5;
      case 'texture_drone':
        return 0.4;

      // Vocals
      case 'word_pulse':
        return 1.2;
      case 'word_sustain':
        return 1.1;

      default:
        return 1.3;
    }
  }

  /// Seek to a new position. Binary-search for the first event at or after [time].
  void seekTo(double time) {
    _nextIdx = _lowerBound(time);
  }

  int _lowerBound(double target) {
    int lo = 0, hi = _allEvents.length;
    while (lo < hi) {
      final mid = (lo + hi) ~/ 2;
      if (_allEvents[mid].time < target) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return lo;
  }

  void stop() {
    _running = false;
    _timer?.cancel();
    _timer = null;
    Vibration.cancel();
  }
}

// ── Device capabilities (from Android getDeviceCaps) ──

class HapticDeviceCaps {
  final bool hasAmplitudeControl;
  final double resonantFrequencyHz;
  final double qFactor;
  final double bandwidthHz;
  final int apiLevel;
  final int minPulseIntervalMs;

  const HapticDeviceCaps({
    this.hasAmplitudeControl = true,
    this.resonantFrequencyHz = 230,
    this.qFactor = 30,
    this.bandwidthHz = 7.7,
    this.apiLevel = 33,
    this.minPulseIntervalMs = 25,
  });

  factory HapticDeviceCaps.fromJson(Map<String, dynamic> json) {
    return HapticDeviceCaps(
      hasAmplitudeControl: json['hasAmplitudeControl'] as bool? ?? true,
      resonantFrequencyHz:
          (json['resonantFrequencyHz'] as num?)?.toDouble() ?? 230,
      qFactor: (json['qFactor'] as num?)?.toDouble() ?? 30,
      bandwidthHz: (json['bandwidthHz'] as num?)?.toDouble() ?? 7.7,
      apiLevel: json['apiLevel'] as int? ?? 33,
      minPulseIntervalMs: json['minPulseIntervalMs'] as int? ?? 25,
    );
  }

  /// Q > 40 = fast actuator (Taptic Engine-like), can handle 10ms pulses.
  bool get isFastActuator => qFactor > 40;
}

// ── Data model (v3/v4 schema) ──

class HapticEvent {
  final double time;
  final double intensity;
  final int durationMs;
  final String type; // v4 types: kick|snare|hihat|crash|bass_beat|bass_slide|bass_sustain|piano_strike|piano_sustain|arpeggio|guitar_strum|guitar_pick|guitar_slide|guitar_mute|synth_pad|orchestral_hit|texture_drone|word_pulse|word_sustain
  final int priority; // 10=kick, 9=snare/crash, 8=bass_beat, 7=strum/hit, 6=piano/pick, 5=word/slide, 4=sustain/arpeggio, 3=pad/mute, 2=drone/hihat
  final String? text; // word text (only for word_pulse/word_sustain)

  const HapticEvent({
    required this.time,
    required this.intensity,
    required this.durationMs,
    required this.type,
    this.priority = 5,
    this.text,
  });

  /// Parse from v3/v4 schema (short keys: t, i, d, tp, prio, txt).
  factory HapticEvent.fromJsonV3(Map<String, dynamic> json) {
    return HapticEvent(
      time: (json['t'] as num?)?.toDouble() ?? 0.0,
      intensity: (json['i'] as num?)?.toDouble() ?? 0.5,
      durationMs: json['d'] as int? ?? 15,
      type: json['tp'] as String? ?? 'beat',
      priority: json['prio'] as int? ?? 5,
      text: json['txt'] as String?,
    );
  }

  /// Parse from v1/v2 schema (long keys: time, intensity, duration_ms, type).
  factory HapticEvent.fromJson(Map<String, dynamic> json) {
    return HapticEvent(
      time: (json['time'] as num?)?.toDouble() ?? 0.0,
      intensity: (json['intensity'] as num?)?.toDouble() ?? 0.5,
      durationMs: json['duration_ms'] as int? ?? 80,
      type: json['type'] as String? ?? 'beat',
      priority: json['prio'] as int? ?? 5,
      text: json['text'] as String? ?? json['txt'] as String?,
    );
  }
}

// ── Native vibration bridge ──

class Vibration {
  static const _channel = MethodChannel('com.chromic/haptic');

  /// Fire a one-shot vibration (6-20ms, capped on Android side too).
  static Future<void> vibrate({
    required int duration,
    required int amplitude,
  }) async {
    // Web has no vibration API via MethodChannel — silent no-op.
    if (kIsWeb) return;

    try {
      await _channel.invokeMethod('vibrate', {
        'durationMs': duration,
        'amplitude': amplitude.clamp(1, 255),
      });
    } catch (e) {
      debugPrint('[VIBRATE] MethodChannel failed: $e');
    }
  }

  /// Query device haptic capabilities from Android.
  static Future<HapticDeviceCaps> getDeviceCaps() async {
    if (kIsWeb) return const HapticDeviceCaps();

    try {
      final result = await _channel.invokeMethod('getDeviceCaps');
      if (result is Map) {
        return HapticDeviceCaps.fromJson(
            Map<String, dynamic>.from(result));
      }
    } catch (e) {
      debugPrint('[VIBRATE] getDeviceCaps failed: $e');
    }
    return const HapticDeviceCaps();
  }

  /// Cancel any running vibration.
  static Future<void> cancel() async {
    if (kIsWeb) return;

    try {
      await _channel.invokeMethod('cancel');
    } catch (e) {
      // ignore
    }
  }
}
