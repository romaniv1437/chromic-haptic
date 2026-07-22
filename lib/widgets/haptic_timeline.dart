import 'package:flutter/material.dart';
import '../engine/haptic_engine.dart';

/// Visual bar showing haptic events as colored vertical markers along a
/// timeline. Useful when you can't test on Android — see what the vibration
/// pattern looks like.
///
/// Filters events by [mode] so the user sees only what the engine is
/// actually firing.
class HapticTimeline extends StatelessWidget {
  final List<HapticEvent> events;
  final HapticMode mode;
  final double playerTime;
  final double totalDuration;
  final double barHeight;

  const HapticTimeline({
    super.key,
    required this.events,
    required this.mode,
    required this.playerTime,
    required this.totalDuration,
    this.barHeight = 48,
  });

  static const _typeColors = {
    'kick': Color(0xFFE53935),         // red
    'snare': Color(0xFF42A5F5),        // blue
    'beat': Color(0xFF4CAF50),         // green
    'bass_beat': Color(0xFF26C6DA),    // cyan
    'bass_slide': Color(0xFF00BCD4),   // teal
    'piano_strike': Color(0xFFFFEB3B), // yellow
    'piano_sustain': Color(0xFFFDD835), // gold
    'guitar_strum': Color(0xFFE91E63), // pink
    'guitar_pick': Color(0xFFEC407A),  // light pink
    'arpeggio': Color(0xFFCE93D8),     // light purple
    'orchestral_hit': Color(0xFFFF9800), // orange
    'synth_pad': Color(0xFF7986CB),    // indigo
    'texture_drone': Color(0xFF90A4AE), // blue-grey
    'hihat': Color(0xFFB0BEC5),        // light grey
    'crash': Color(0xFFFFC107),        // amber
    'word_pulse': Color(0xFFAB47BC),
    'word_sustain': Color(0xFF7E57C2),
  };

  static const _defaultColor = Color(0xFFFFB74D);

  static bool _isInstrumentalType(String type) {
    return type != 'word_pulse' && type != 'word_sustain';
  }

  /// Events visible under the current mode.
  static List<HapticEvent> _filtered(List<HapticEvent> events, HapticMode mode) {
    if (mode == HapticMode.both || mode == HapticMode.full) return events;
    return events.where((e) {
      switch (mode) {
        case HapticMode.beat:
        case HapticMode.instrumental:
          return _isInstrumentalType(e.type);
        case HapticMode.word:
          return e.type == 'word_pulse' || e.type == 'word_sustain';
        case HapticMode.both:
        case HapticMode.full:
          return true;
      }
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    final visible = _filtered(events, mode);
    return SizedBox(
      height: barHeight + 24,
      child: Stack(
        children: [
          // Label
          const Positioned(
            top: 0,
            left: 8,
            child: Text('Haptics',
                style: TextStyle(color: Colors.white24, fontSize: 10)),
          ),
          // Stats chip
          Positioned(
            top: 0,
            right: 8,
            child: _StatsChip(events: visible, mode: mode),
          ),
          // Timeline bar
          Positioned(
            left: 0,
            right: 0,
            bottom: 4,
            child: CustomPaint(
              painter: _HapticTimelinePainter(
                events: visible,
                playerTime: playerTime,
                totalDuration: totalDuration,
                mode: mode,
              ),
              size: Size(double.infinity, barHeight),
            ),
          ),
        ],
      ),
    );
  }
}

class _StatsChip extends StatelessWidget {
  final List<HapticEvent> events;
  final HapticMode mode;
  const _StatsChip({required this.events, required this.mode});

  @override
  Widget build(BuildContext context) {
    final kicks = events.where((e) => e.type == 'kick').length;
    final snares = events.where((e) => e.type == 'snare').length;
    final beats = events.where((e) => e.type == 'beat').length;
    final bass = events.where((e) => e.type == 'bass_beat' || e.type == 'bass_slide' || e.type == 'bass_sustain').length;
    final piano = events.where((e) => e.type == 'piano_strike' || e.type == 'piano_sustain').length;
    final guitar = events.where((e) => e.type == 'guitar_strum' || e.type == 'guitar_pick' || e.type == 'guitar_slide' || e.type == 'guitar_mute').length;
    final arpeggios = events.where((e) => e.type == 'arpeggio').length;
    final pulses = events.where((e) => e.type == 'word_pulse').length;
    final sustains = events.where((e) => e.type == 'word_sustain').length;

    final parts = <String>[];
    if (kicks > 0) parts.add('$kicks kick');
    if (snares > 0) parts.add('$snares snare');
    if (beats > 0) parts.add('$beats beat');
    if (bass > 0) parts.add('$bass bass');
    if (piano > 0) parts.add('$piano piano');
    if (guitar > 0) parts.add('$guitar gtr');
    if (arpeggios > 0) parts.add('$arpeggios arp');
    if (pulses > 0) parts.add('$pulses pulse');
    if (sustains > 0) parts.add('$sustains sustain');

    final modeLabel = switch (mode) {
      HapticMode.both => 'beat+word',
      HapticMode.beat => 'beat',
      HapticMode.word => 'word',
      HapticMode.instrumental => 'instr',
      HapticMode.full => 'full',
    };
    parts.add('$modeLabel');

    return Text(parts.join(' · '),
        style: const TextStyle(color: Colors.white24, fontSize: 10));
  }
}

class _HapticTimelinePainter extends CustomPainter {
  final List<HapticEvent> events;
  final double playerTime;
  final double totalDuration;
  final HapticMode mode;

  _HapticTimelinePainter({
    required this.events,
    required this.playerTime,
    required this.totalDuration,
    required this.mode,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (events.isEmpty || totalDuration <= 0) return;

    final h = size.height;
    final w = size.width;
    final maxIntensity =
        events.map((e) => e.intensity).reduce((a, b) => a > b ? a : b);
    final paint = Paint()..style = PaintingStyle.fill;

    // Background line
    paint.color = Colors.white12;
    canvas.drawRect(
      Rect.fromLTWH(0, h / 2 - 0.5, w, 1),
      paint,
    );

    // Event bars (already filtered by mode before reaching painter)
    final barWidth = 2.0;
    for (final evt in events) {
      final x = (evt.time / totalDuration).clamp(0.0, 1.0) * w;
      final intensity = maxIntensity > 0 ? evt.intensity / maxIntensity : 0.3;
      final barH = (4 + intensity * (h - 12)).clamp(4.0, h - 4);

      paint.color = (HapticTimeline._typeColors[evt.type] ??
              HapticTimeline._defaultColor)
          .withValues(alpha: 0.3 + intensity * 0.7);

      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromCenter(
              center: Offset(x, h / 2), width: barWidth, height: barH),
          const Radius.circular(1),
        ),
        paint,
      );
    }

    // Legend dots — show only types present in current mode
    const dotRadius = 3.0;
    double legendX = 6;
    // Show beat types first, then word types — but only types relevant to the mode
    final orderedTypes = switch (mode) {
      HapticMode.word => ['word_pulse', 'word_sustain'],
      HapticMode.instrumental || HapticMode.beat => ['kick', 'snare', 'bass_beat', 'piano_strike', 'guitar_strum', 'arpeggio', 'beat'],
      _ => ['kick', 'snare', 'bass_beat', 'piano_strike', 'guitar_strum', 'arpeggio', 'beat', 'word_pulse', 'word_sustain'],
    };
    for (final typeName in orderedTypes) {
      final hasType = events.any((e) => e.type == typeName);
      if (!hasType) continue;

      paint.color =
          HapticTimeline._typeColors[typeName] ?? HapticTimeline._defaultColor;
      canvas.drawCircle(Offset(legendX, h - dotRadius - 2), dotRadius, paint);
      legendX += dotRadius * 2 + 4;
    }

    // Player position line
    final posX = (playerTime / totalDuration).clamp(0.0, 1.0) * w;
    paint.color = Colors.white.withValues(alpha: 0.6);
    paint.strokeWidth = 1.5;
    paint.style = PaintingStyle.stroke;
    canvas.drawLine(Offset(posX, 2), Offset(posX, h - 2), paint);

    // Position dot
    paint.style = PaintingStyle.fill;
    paint.color = Colors.white;
    canvas.drawCircle(Offset(posX, h / 2), 3, paint);
  }

  @override
  bool shouldRepaint(_HapticTimelinePainter old) =>
      old.playerTime != playerTime || old.events != events;
}
