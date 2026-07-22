import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import '../models/lyric_models.dart';


/// Renders lyrics matching Troika Three.js LyricsRenderer behaviour.
///
/// Per-word fill paragraphs — each word gets its own ui.Paragraph (like
/// Troika's per-word Troika-text meshes). This isolates word fills so
/// feather can extend past word boundary without cross-word bleed, and
/// ensures word-level fill timing is independent of line state.
///
/// Char-split per-char fill for words with valid char_starts uses
/// per-character boxes from the word's own paragraph for accuracy.
/// Line state machine: active/past/future/adlib.
///
/// Troika design tokens:
///   UNFILLED = 0.5 (base text opacity multiplier)
///   FILLED   = 1.0 (fill text opacity multiplier)
///   FEATHER  = 0.15 (multiplicative clip edge blend)
class LyricPainter extends CustomPainter {
  final List<LyricLine> lines;
  final double playerTime;
  final Color fillColor;
  final Color unfilledColor;
  final double fontSize;
  final int visibleLineCount;
  final double featherRatio;
  final double textMaxWidthRatio;

  /// Per-line animated opacity (lerped each frame).
  final Map<int, double>? cOp;

  /// Per-line animated Y offset.
  final Map<int, double>? cOy;

  /// Per-line parallax lag (velocity-driven, disabled — decay-only).
  final Map<int, double>? scrollLag;

  /// [DEPRECATED] Use cOp instead. Kept for hitTestWord compat.
  final Map<int, double>? smoothedOpacities;



  /// Manual scroll offset in logical pixels (positive = scroll backward/up).
  /// Decays back to 0 when user stops dragging.
  final double manualScrollOffset;

  /// True when user is manually dragging to scroll (disables state-based dimming).
  final bool isScrolling;

  /// Lerped scroll position from parent (smooth transition between lines).
  final double smoothSy;

  /// Whether playback has ever started (controls cue dot static vs animated state).
  final bool trackStarted;

  /// Notifies parent of target scroll position + valid manual-scroll bounds.
  /// [targetSy] — lerp target. [minManual] / [maxManual] — valid range for manualScrollOffset.
  final void Function(double targetSy, double minManual, double maxManual)? onLayout;

  /// Optional char-glow fragment program (char_glow.frag).
  /// When non-null and word is stretch, draws per-char glow behind fill.
  final ui.FragmentProgram? glowProgram;

  // Cached canvas size, set at start of paint().
  Size _canvasSize = Size.zero;

  // ── Love-wave stateful smoothing (Troika: per-mesh _lerpScY / _lerpScX) ──
  double _lastPlayerTime = -1.0;
  final Map<String, double> _wordWaves = {};  // key → lerpScY (smoothed Y scale)
  final Map<String, double> _wordGlows = {};  // key → lerpScX (smoothed X scale)


  LyricPainter({
    required this.lines,
    required this.playerTime,
    this.fillColor = Colors.white,
    this.unfilledColor = Colors.white,
    this.fontSize = 28,
    this.visibleLineCount = 7,
    this.featherRatio = 0.15,
    this.textMaxWidthRatio = 0.85,
    this.cOp,
    this.cOy,
    this.scrollLag,
    this.smoothedOpacities,
    this.manualScrollOffset = 0.0,
    this.isScrolling = false,
    this.smoothSy = 0.0,
    this.trackStarted = false,
    this.onLayout,
    this.glowProgram,
  });

  // ── Troika design tokens ──
  static const double _UNFILLED = 0.5;
  static const double _FILLED = 0.9;   // regular words max opacity; stretch → 1.0 for bloom glow
  static const double _FS_AD_RATIO = 0.65;

  // ── State opacity targets (matches Troika S table) ──
  static const double _ACTIVE_OP = 1.0;
  static const double _PAST_OP = 0.0;       // past lines hidden in auto-scroll
  static const double _PAST_FAR_OP = 0.0;
  static const double _FUTURE1_OP = 0.55;
  static const double _FUTURE2_OP = 0.30;
  static const double _FUTURE3_OP = 0.14;
  static const double _FUTURE4_OP = 0.07;
  static const double _FUTURE_FAR_OP = 0.07;
  static const double _SCROLL_OP = 0.7;     // manual scroll — all non-active lines
  static const double _SCROLL_ACT_OP = 1.0; // manual scroll — active line
  // ── Adlib-specific opacities (Troika: adlibOn/Off/Hid) ──
  static const double _ADLIB_ON_OP = 0.6;
  static const double _ADLIB_OFF_OP = 0.35;
  static const double _ADLIB_HID_OP = 0.0;

  // ── Public smoothing API (called by parent widget to drive cross-frame lerp) ──

  static Map<int, double> computeTargetOpacities(
    List<LyricLine> lines,
    double playerTime, {
    bool isScrolling = false,
  }) {
    final result = <int, double>{};
    if (lines.isEmpty) return result;
    final ai = findActiveIdx(lines, playerTime);
    for (int i = 0; i < lines.length; i++) {
      final state = stateForLine(lines, i, ai, playerTime);
      result[i] = stateOpacity(i, ai, state, isScrolling: isScrolling);
    }
    return result;
  }

  static Map<int, double> smoothOpacities(
    Map<int, double> smoothed,
    Map<int, double> targets,
    double dt, {
    double lerpSpeed = 5.0,
  }) {
    final f = 1 - math.exp(-lerpSpeed * dt.clamp(0.0, 0.1));
    for (final entry in targets.entries) {
      final idx = entry.key;
      final target = entry.value;
      final current = smoothed[idx] ?? target;
      final next = current + (target - current) * f;
      if ((next - target).abs() < 0.002) {
        smoothed[idx] = target;
      } else {
        smoothed[idx] = next;
      }
    }
    return smoothed;
  }

  /// Public: find active line index for given time (used by FluidCascadeAnimator).
  static int findActiveIdx(List<LyricLine> lines, double t) {
    if (lines.isEmpty) return 0;
    for (int i = 0; i < lines.length; i++) {
      final le = _staticLineEnd(lines, i);
      if (t >= lines[i].time && t <= le) return i;
    }
    for (int i = 0; i < lines.length; i++) {
      if (lines[i].time > t) return i;
    }
    return lines.length - 1;
  }

  /// Public: determine line state (used by FluidCascadeAnimator).
  /// All-adlib lines (non-standalone) return LineState.adlib.
  /// Standalone adlib lines behave like normal lines.
  static LineState stateForLine(List<LyricLine> lines, int li, int ai, double t) {
    final line = lines[li];
    if (_staticIsAdlibLine(line)) {
      if (_isStandaloneAdlibLine(lines, li)) {
        if (li < ai) return LineState.past;
        if (li == ai) {
          final le = _staticLineEnd(lines, li);
          if (t >= line.time && t <= le) return LineState.active;
          if (t < line.time) return LineState.future;
          return LineState.past;
        }
        return LineState.future;
      }
      return LineState.adlib;
    }
    if (li < ai) return LineState.past;
    if (li == ai) {
      final le = _staticLineEnd(lines, li);
      if (t >= line.time && t <= le) return LineState.active;
      if (t < line.time) return LineState.future;
      return LineState.past;
    }
    return LineState.future;
  }

  // ── Private line-state helpers (thin wrappers around public statics) ──

  static double _staticLineEnd(List<LyricLine> lines, int idx) {
    return _lineEndFor(lines[idx], idx, lines);
  }

  static bool _staticIsAdlibLine(LyricLine line) {
    if (line.isVocalCue || line.words.isEmpty) return false;
    if (line.adlib) return true;
    for (final w in line.words) {
      if (!w.flags.contains('adlib')) return false;
    }
    return true;
  }

  /// Some but not all words have adlib flag - inline adlibs within a normal line.
  static bool _hasInlineAdlibs(LyricLine line) {
    if (line.isVocalCue || _staticIsAdlibLine(line) || line.words.isEmpty) return false;
    for (final w in line.words) {
      if (w.flags.contains('adlib')) return true;
    }
    return false;
  }

  /// Standalone adlib line: all-adlib, not paired with another parenthesized line.
  /// These behave like normal lines instead of fading adlib states.
  static bool _isStandaloneAdlibLine(List<LyricLine> lines, int li) {
    if (!_staticIsAdlibLine(lines[li])) return false;
    final text = lines[li].text.trim();
    if (text.startsWith('(') && li + 1 < lines.length) {
      final nextText = lines[li + 1].text.trim();
      if (nextText.startsWith('(')) return false;
    }
    if (li > 0) {
      final prevText = lines[li - 1].text.trim();
      if (prevText.startsWith('(') && text.startsWith('(')) return false;
    }
    return true;
  }

  /// Public: compute target opacity for a line given its state and scroll mode.
  /// Matches Troika S-table: past=0 (hidden), active=1, future fades.
  /// In manual-scroll mode, all non-active lines use SCROLL_OP (0.7).
  static double stateOpacity(int li, int ai, LineState s, {bool isScrolling = false}) {
    if (isScrolling) return li == ai ? _SCROLL_ACT_OP : _SCROLL_OP;
    switch (s) {
      case LineState.active: return _ACTIVE_OP;
      case LineState.past: return (ai - li) > 3 ? _PAST_FAR_OP : _PAST_OP;
      case LineState.adlib: return li == ai ? _ADLIB_ON_OP : li < ai ? _ADLIB_OFF_OP : _ADLIB_HID_OP;
      case LineState.future:
        final d = li - ai;
        if (d == 1) return _FUTURE1_OP;
        if (d == 2) return _FUTURE2_OP;
        if (d == 3) return _FUTURE3_OP;
        return _FUTURE_FAR_OP;
    }
  }

  // ── Line state detection ──

  int _findActiveIdx() {
    if (lines.isEmpty) return 0;
    for (int i = 0; i < lines.length; i++) {
      final le = _lineEnd(lines[i], i);
      if (playerTime >= lines[i].time && playerTime <= le) return i;
    }
    for (int i = 0; i < lines.length; i++) {
      if (lines[i].time > playerTime) return i;
    }
    return lines.length - 1;
  }

  /// Safe line-end computation: prefers explicit end, then last word end,
  /// then next-line time, then +3s fallback.
  /// Order matters: word-based end is tighter than next-line-time gap.
  static double _lineEndFor(LyricLine line, int idx, List<LyricLine> allLines) {
    if (line.end != null) return line.end!;
    if (line.words.isNotEmpty) return line.words.last.end;
    if (idx + 1 < allLines.length) return allLines[idx + 1].time;
    return line.time + 3.0;
  }

  double _lineEnd(LyricLine line, int idx) => _lineEndFor(line, idx, lines);

  bool _isAdlibLine(LyricLine line) => _staticIsAdlibLine(line);

  LineState _stateForLine(int li, int ai, LyricLine line) {
    if (_isAdlibLine(line)) {
      if (_isStandaloneAdlibLine(lines, li)) {
        if (li < ai) return LineState.past;
        if (li == ai) {
          final le = _lineEnd(line, li);
          if (playerTime >= line.time && playerTime <= le) return LineState.active;
          if (playerTime < line.time) return LineState.future;
          return LineState.past;
        }
        return LineState.future;
      }
      return LineState.adlib;
    }
    if (li < ai) return LineState.past;
    if (li == ai) {
      final le = _lineEnd(line, li);
      if (playerTime >= line.time && playerTime <= le) return LineState.active;
      if (playerTime < line.time) return LineState.future;
      return LineState.past;
    }
    return LineState.future;
  }

  double _stateOpacity(int li, int ai, LineState s) => stateOpacity(li, ai, s, isScrolling: isScrolling);

  // ── Troika layout constants (exact ratios from LyricsRenderer.ts) ──
  static const double _LINE_SPACING_RATIO = 1.556; // LINE_HEIGHT/FONT_SIZE = 0.14/0.09
  static const double _ACTIVE_LINE_Y_RATIO = 0.15;  // active line at 15% from top

  // ── Paint ──

  @override
  void paint(Canvas canvas, Size size) {
    _canvasSize = size;
    if (lines.isEmpty) return;

    final realAi = _findActiveIdx();
    final ai = realAi;

    final textMaxW = size.width * textMaxWidthRatio;
    final dx = (size.width - textMaxW) / 2;

    // Pass 1: layout ALL lines (scroll system handles culling)
    final layouts = <_LineLayout?>[];
    final lineHeights = <double>[];

    for (int i = 0; i < lines.length; i++) {
      final line = lines[i];
      final gap = fontSize * _LINE_SPACING_RATIO;

      if (line.isVocalCue) {
        // Same total line height as a normal single-line lyric entry.
        // Normal: contentHeight + gap ≈ fontSize + gap.
        // Troika: yPos -= LINE_HEIGHT for every line type uniformly.
        layouts.add(null);
        lineHeights.add(fontSize + gap);
        continue;
      }
      final state = _stateForLine(i, ai, line);
      final animOp = cOp != null ? (cOp![i] ?? 1.0) : _stateOpacity(i, ai, state);
      final sop = smoothedOpacities != null
          ? (smoothedOpacities![i] ?? animOp)
          : animOp;

      final layout = _layoutLine(line, state, sop, textMaxW, i);
      layouts.add(layout);
      if (layout != null) {
        lineHeights.add(layout.contentHeight + gap);
      } else {
        lineHeights.add(gap);
      }
    }

    // ── Active line at exactly _ACTIVE_LINE_Y_RATIO from top ──
    // Compute real activeBaseY from actual line heights (not avg)
    double activeTopOffset = 0;
    for (int i = 0; i < ai && i < lineHeights.length; i++) {
      activeTopOffset += lineHeights[i];
    }
    final targetSy = size.height * _ACTIVE_LINE_Y_RATIO - activeTopOffset - manualScrollOffset;
    final totalH = lineHeights.fold(0.0, (sum, h) => sum + h);
    // Allow scrolling through all content. Small margin at edges for comfort.
    final margin = fontSize * 2.0;
    final minTargetSy = math.min(0.0, size.height - totalH) - margin;
    final maxTargetSy = math.max(0.0, size.height - totalH) + margin;
    final minManual = size.height * _ACTIVE_LINE_Y_RATIO - activeTopOffset - maxTargetSy;
    final maxManual = size.height * _ACTIVE_LINE_Y_RATIO - activeTopOffset - minTargetSy;
    onLayout?.call(targetSy, minManual, maxManual);

    // Pass 2: render (use lerped smoothSy for smooth transitions)
    double baseY = 0;

    for (int i = 0; i < lines.length; i++) {
      final line = lines[i];
      final layout = layouts[i];
      final lh = lineHeights[i];

      final cOyVal = cOy != null ? (cOy![i] ?? 0.0) : 0.0;
      final lagVal = scrollLag != null ? (scrollLag![i] ?? 0.0) : 0.0;

      final lineScreenY = baseY + smoothSy + cOyVal - lagVal;

      // Cull off-screen
      if (lineScreenY < -lh || lineScreenY > size.height + lh) {
        baseY += lh;
        continue;
      }

      if (layout == null) {
        if (line.isVocalCue) {
          final vcOp = cOp != null ? (cOp![i] ?? 0.5) : 0.5;
          final state = _stateForLine(i, ai, line);
          final isActive = state == LineState.active;
          _drawVocalCueDots(canvas, dx, lineScreenY + fontSize * 0.22, line, vcOp, isActive);
        }
        baseY += lh;
        continue;
      }

      final state = _stateForLine(i, ai, line);
      final isPast = state == LineState.past;
      final isActive = state == LineState.active;
      final isAdlibState = state == LineState.adlib;
      // Animated opacity from cOp (past-0 during auto-scroll, visible during manual)
      final animOp2 = cOp != null ? (cOp![i] ?? 1.0) : _stateOpacity(i, ai, state);

      if (layout.wordFills.isEmpty) { baseY += lh; continue; }

      canvas.save();

      // Base layer: draw main paragraph
      // - Skip past lines (fully transparent)
      // - Skip all-adlib lines (past already handled; future all-adlib are hidden)
      if (!isPast && !isAdlibState) {
        canvas.drawParagraph(layout.paragraph, Offset(dx, lineScreenY));
        // Two-tier inline adlib: draw adlib paragraph below main text
        if (layout.adlibParagraph != null) {
          final adlibY = lineScreenY + layout.paragraph.height + layout.adlibGap;
          canvas.drawParagraph(layout.adlibParagraph!, Offset(dx, adlibY));
        }
      }

      // Fill layer: per-word clip-fill - gate on animated opacity
      // For adlib lines, always draw fills since base is not rendered
      if ((isActive || isPast || isAdlibState) && animOp2 > 0.01) {
        _drawFills(canvas, layout, lineScreenY, dx, isPast);
      }

      canvas.restore();

      baseY += lh;
    }
  }

  /// Per-word fill drawing — each word gets its own paragraph + clipRect.
  /// Uses wordBox from the full-line paragraph for accurate positions.
  /// For inline adlib lines, adlib fills are drawn below main fills.
  void _drawFills(Canvas canvas, _LineLayout layout, double sy, double dx, bool isPast) {
    // Pre-compute dt for love-wave overlay smoothing
    final dt = _lastPlayerTime > 0 ? math.max(0.001, playerTime - _lastPlayerTime) : 0.016;
    _lastPlayerTime = playerTime;

    // Main word fills
    for (int wi = 0; wi < layout.wordFills.length; wi++) {
      _drawOneFill(canvas, layout.wordFills[wi], sy, dx, isPast, dt, false);
    }

    // Inline adlib fills — offset below main text
    if (layout.adlibFills != null && layout.adlibFills!.isNotEmpty) {
      final adlibOffsetY = layout.paragraph.height + layout.adlibGap;
      final adlibSy = sy + adlibOffsetY;
      for (int wi = 0; wi < layout.adlibFills!.length; wi++) {
        _drawOneFill(canvas, layout.adlibFills![wi], adlibSy, dx, isPast, dt, true);
      }
    }
  }

  void _drawOneFill(Canvas canvas, _WordFill wf, double sy, double dx, bool isPast, double dt, bool isAdlibRow) {
    final wordBox = wf.wordBox;
    final wy = sy + wordBox.top;
    final wx = dx + wordBox.left;

    if (isPast) {
      canvas.drawParagraph(wf.paragraph, Offset(wx, wy));
      return;
    }

    // Adlib word: sweep fill + 0.2s fade-in from effStart, darker color from paragraph
    if (wf.isAdlib) {
      final fadeT = ((playerTime - wf.effStart) / 0.2).clamp(0.0, 1.0);
      if (fadeT <= 0.01) return;

      final p = _clampProgress(wf.wordStart, wf.wordEnd, wf.effStart);
      if (p > 0) {
        final wordW = wordBox.right - wordBox.left;
        final wordH = wordBox.bottom - wordBox.top;
        final isFilled = p >= 1.0;
        final clipRight = isFilled ? wordW + wordW * featherRatio : wordW * p + wordW * featherRatio;
        final clipRect = Rect.fromLTRB(wx, wy, wx + clipRight, wy + wordH);

        canvas.saveLayer(clipRect, Paint()..color = ui.Color.fromRGBO(255, 255, 255, fadeT));
        canvas.drawParagraph(wf.paragraph, Offset(wx, wy));
        if (!isFilled) {
          final fadeStartX = wx + clipRight - wordW * featherRatio;
          final fadePaint = Paint()
            ..shader = ui.Gradient.linear(
              Offset(fadeStartX, 0), Offset(wx + clipRight, 0),
              [const Color(0xFFFFFFFF), const Color(0x00FFFFFF)],
            )
            ..blendMode = BlendMode.dstIn;
          canvas.drawRect(clipRect, fadePaint);
        }
        canvas.restore();
      }
      return;
    }

      // Per-character fill with BACKEND char timing
      if (wf.isCharSplit && wf.hasCharTiming) {
        _drawCharSplitFill(canvas, wf, wy, wx, dt);
        return;
      }

      // ── Regular whole-word fill (sweep from left to right) ──
      final effEnd = wf.isStretch
          ? wf.wordEnd + (wf.wordEnd - wf.wordStart) * 0.15
          : wf.wordEnd;
      final p = _clampProgress(wf.wordStart, effEnd, wf.effStart);

      if (p > 0) {
        final wordW = wordBox.right - wordBox.left;
        final wordH = wordBox.bottom - wordBox.top;
        final isFilled = p >= 1.0;
        final clipRight = isFilled ? wordW + wordW * featherRatio : wordW * p + wordW * featherRatio;
        final clipRect = Rect.fromLTRB(wx, wy, wx + clipRight, wy + wordH);

        if (isFilled) {
          // Fully filled: overshooting clip invisible past word edge → no feather needed
          canvas.save();
          canvas.clipRect(clipRect);
          canvas.drawParagraph(wf.paragraph, Offset(wx, wy));
          if (wf.isStretch && !wf.hasCharTiming) {
            _drawLoveWaveOverlay(canvas, wf, wy, wx, dt);
          }
          canvas.restore();
        } else {
          // Partially filled: gradient feather at leading edge (Troika FEATHER token)
          final fadeStartX = wx + clipRight - wordW * featherRatio;
          canvas.saveLayer(clipRect, Paint());
          canvas.drawParagraph(wf.paragraph, Offset(wx, wy));
          if (wf.isStretch && !wf.hasCharTiming) {
            _drawLoveWaveOverlay(canvas, wf, wy, wx, dt);
          }
          final fadePaint = Paint()
            ..shader = ui.Gradient.linear(
              Offset(fadeStartX, 0),
              Offset(wx + clipRight, 0),
              [Colors.white, Colors.white.withOpacity(0)],
            )
            ..blendMode = BlendMode.dstIn;
          canvas.drawRect(clipRect, fadePaint);
          canvas.restore();
        }
      }
  }

  void _drawCharSplitFill(Canvas canvas, _WordFill wf, double wy, double wx, double dt) {
    final wordText = wf.wordText;
    if (wordText.isEmpty) return;

    // Rebuild character boxes from the word paragraph
    final boxes = wf.paragraph.getBoxesForRange(0, wordText.length);
    if (boxes.isEmpty) {
      canvas.drawParagraph(wf.paragraph, Offset(wx, wy));
      return;
    }

    // Map boxes to character indices
    final charBoxes = <_CharBox>[];
    for (final tb in boxes) {
      for (int ci = tb.start.toInt(); ci < tb.end.toInt() && ci < wordText.length; ci++) {
        charBoxes.add(_CharBox(
          index: ci,
          rect: Rect.fromLTRB(tb.left, tb.top, tb.right, tb.bottom),
        ));
      }
    }

    final hasCharTiming = wf.charStarts.length == charBoxes.length && wf.charStarts.length > 1;
    final n = charBoxes.length;
    if (n == 0) return;

    final wordDur = wf.wordEnd - wf.wordStart;

    // ── Word-level fill sweep (multiplicative feather, no pre-fill) ──
    // Sweeps evenly across full word duration with dynamic gradient edge.
    // Multiplicative: feather scales with progress → zero at start, visible as fill grows.
    final wordBox = wf.wordBox;
    final wordW = wordBox.right - wordBox.left;
    final wordH = wordBox.bottom - wordBox.top;
    final wordFillProgress = wordDur > 0
        ? math.max(0, math.min(1, (playerTime - wf.wordStart) / wordDur))
        : 0.0;
    const wordFeatherRatio = 0.40; // feather relative to fill progress
    final wordFullyFilled = wordFillProgress >= 1.0;
    // Clip extends past fill edge — feather lives in empty overshoot, not on characters.
    final wordClipRight = wordFullyFilled
        ? wordW * 1.12
        : wordW * wordFillProgress * (1 + wordFeatherRatio);
    final wordFeatherW = wordFullyFilled ? 0.0 : wordW * wordFillProgress * wordFeatherRatio;

    if (wordClipRight > 0) {
      final wordClip = Rect.fromLTRB(wx, wy, wx + wordClipRight, wy + wordH);

      // Always saveLayer for consistent compositing — no mode switch at full-fill.
      canvas.saveLayer(wordClip, Paint());

      // Draw full word fill inside the sweep clip
      canvas.drawParagraph(wf.paragraph, Offset(wx, wy));

      // ── Per-character love-wave overlay (stretch words) ──
      if (wf.isStretch) {
        final extDur = wordDur * 1.15;
        final waveProgressLocal = extDur > 0
            ? ((playerTime - wf.wordStart) / extDur).clamp(0.0, 1.0)
            : 0.0;
        final reverseExitDur = wordDur * 0.5;
        final reverseProgressLocal = (playerTime > wf.wordEnd)
            ? ((playerTime - wf.wordEnd) / reverseExitDur).clamp(0.0, 1.0)
            : 0.0;

        double wavePos;
        if (hasCharTiming) {
          if (playerTime <= wf.charStarts.first) {
            wavePos = 0;
          } else if (playerTime >= wf.wordEnd) {
            wavePos = (n - 1).toDouble();
          } else {
            wavePos = 0;
            for (int cj = 0; cj < n; cj++) {
              final cStart = wf.charStarts[cj];
              final cEnd = (cj + 1) < n
                  ? math.max(cStart + 0.01, wf.charStarts[cj + 1])
                  : math.max(cStart + 0.01, wf.wordEnd);
              if (playerTime < cEnd || cj == n - 1) {
                final local = math.max(0, math.min(1,
                    (playerTime - cStart) / math.max(0.01, cEnd - cStart)));
                wavePos = math.min(n - 1, cj + local).toDouble();
                break;
              }
            }
          }
        } else {
          wavePos = waveProgressLocal * (n - 1);
        }
        const sigma = 2.2;
        const scaleDt = 1.0 / 60.0;
        const scaleLerpSpeed = 5.0;
        final scaleLerp = 1.0 - math.exp(-scaleLerpSpeed * scaleDt);

        bool anyWaveActive = false;
        for (int ci = 0; ci < n; ci++) {
          final dist = ci - wavePos;
          final forwardWave = (playerTime > wf.wordStart && playerTime < wf.wordEnd)
              ? math.exp(-(dist * dist) / (2 * sigma * sigma))
              : 0.0;
          final reverseWavePos = (n > 1) ? (n - 1) - reverseProgressLocal * (n - 1) : 0.0;
          final reverseDist = ci - reverseWavePos;
          final reverseWave = (reverseProgressLocal > 0 && reverseProgressLocal < 1)
              ? math.exp(-(reverseDist * reverseDist) / (2 * sigma * sigma)) * (1.0 - reverseProgressLocal)
              : 0.0;
          final wave = forwardWave + reverseWave;

          final targetScY = 1.0 + 0.40 * wave;
          final targetScX = 1.0 + 0.07 * wave;

          final wordKey = '${wf.wordStart}_$ci';
          double lerpScY = _wordWaves[wordKey] ?? 1.0;
          lerpScY += (targetScY - lerpScY) * scaleLerp;
          _wordWaves[wordKey] = lerpScY;

          double lerpScX = _wordGlows[wordKey] ?? 1.0;
          lerpScX += (targetScX - lerpScX) * scaleLerp;
          _wordGlows[wordKey] = lerpScX;

          final doWave = (lerpScY - 1.0).abs() > 0.001 || (lerpScX - 1.0).abs() > 0.001;
          if (!doWave && wave < 0.005) continue;
          anyWaveActive = true;

          final chBox = charBoxes[ci].rect;
          final chCenterX = chBox.center.dx + wx;
          final chBottom = wy + chBox.bottom;
          final charHeight = chBox.bottom - chBox.top;

          final chRect = Rect.fromLTRB(
            chBox.left + wx, wy + chBox.top - charHeight * 0.2,
            chBox.right + wx, wy + chBox.bottom,
          );

          canvas.save();
          canvas.clipRect(chRect);
          canvas.save();
          canvas.translate(chCenterX, chBottom);
          canvas.scale(lerpScX, lerpScY);
          canvas.translate(-chCenterX, -chBottom);
          canvas.drawParagraph(wf.paragraph, Offset(wx, wy));
          canvas.restore();
          canvas.restore();
        }

        if (!anyWaveActive && playerTime > wf.wordEnd + math.max(1.0, wordDur * 0.5)) {
          _wordWaves.removeWhere((k, _) => k.startsWith('${wf.wordStart}_'));
          _wordGlows.removeWhere((k, _) => k.startsWith('${wf.wordStart}_'));
        }
      }

      // Gradient feather at leading edge (word-level, smooth).
      // Only during sweep — fully filled words render clean, no edge fade needed.
      if (!wordFullyFilled) {
        final fadeStartX = wx + wordClipRight - wordFeatherW;
        final fadePaint = Paint()
          ..shader = ui.Gradient.linear(
            Offset(fadeStartX, 0),
            Offset(wx + wordClipRight, 0),
            [Colors.white, Colors.white.withOpacity(0)],
          )
          ..blendMode = BlendMode.dstIn;
        canvas.drawRect(wordClip, fadePaint);
      }

      canvas.restore(); // saveLayer
    }

    // Cleanup: remove entries for past words (playerTime well past word end)
    if (playerTime > wf.wordEnd + 2.0) {
      _wordWaves.removeWhere((k, _) => k.startsWith('${wf.wordStart}_'));
      _wordGlows.removeWhere((k, _) => k.startsWith('${wf.wordStart}_'));
    }
  }

  /// Love-wave overlay: per-character Gaussian scale breathed on top of
  /// regular whole-word fill sweep. Only for stretch words without backend
  /// char timing (fill handles reveal; wave breathes scale only).
  /// Matches Troika char-split wave: sigma=2.2 Gaussian, dt*9 lerp, 15% postroll.
  void _drawLoveWaveOverlay(Canvas canvas, _WordFill wf, double wy, double wx, double dt) {
    final boxes = wf.paragraph.getBoxesForRange(0, wf.wordText.length);
    if (boxes.isEmpty) return;

    final charBoxes = <_CharBox>[];
    for (final tb in boxes) {
      for (int ci = tb.start.toInt(); ci < tb.end.toInt() && ci < wf.wordText.length; ci++) {
        charBoxes.add(_CharBox(index: ci, rect: Rect.fromLTRB(tb.left, tb.top, tb.right, tb.bottom)));
      }
    }

    final n = charBoxes.length;
    if (n == 0) return;

    final wordDur = wf.wordEnd - wf.wordStart;
    // Wave trail-off: 15% postroll past wordEnd (Troika extDur)
    final extDur = wordDur * 1.15;
    final waveProgress = extDur > 0
        ? ((playerTime - wf.wordStart) / extDur).clamp(0.0, 1.0)
        : 0.0;

    // ── Reverse exit wave: sweep right→left after forward wave completes ──
    final reverseExitDur = wordDur * 0.5;
    final reverseProgress = (playerTime > wf.wordEnd)
        ? ((playerTime - wf.wordEnd) / reverseExitDur).clamp(0.0, 1.0)
        : 0.0;

    // ── Smoothed wave position (lerp toward target, dt*9 rate) ──
    final smoothRate = math.min(1.0, dt * 9.0);
    final targetWavePos = waveProgress * (n - 1).toDouble();
    final posKey = '__wpos_${wf.wordStart}';
    double smoothedWavePos = _wordWaves[posKey] ?? targetWavePos;
    smoothedWavePos += (targetWavePos - smoothedWavePos) * smoothRate;
    _wordWaves[posKey] = smoothedWavePos;

    const sigma = 2.2;
    // ── Troika scale lerp: hardcoded dt=1/60 (matching Troika LERP_SPEED=5.0) ──
    const scaleDt = 1.0 / 60.0;
    const scaleLerpSpeed = 5.0;
    final scaleLerp = 1.0 - math.exp(-scaleLerpSpeed * scaleDt);

    bool anyActive = false;
    for (int ci = 0; ci < n; ci++) {
      // ── Raw Gaussian wave: forward sweep (ends at wordEnd) + reverse exit ──
      final dist = ci - smoothedWavePos;
      final forwardWave = (playerTime > wf.wordStart && playerTime < wf.wordEnd)
          ? math.exp(-(dist * dist) / (2 * sigma * sigma))
          : 0.0;
      // Reverse exit: starts at wordEnd, same Gaussian center → continuous transition.
      // Sweeps right→left, intensity fades (1−progress).
      final reverseWavePos = (n > 1) ? (n - 1) - reverseProgress * (n - 1) : 0.0;
      final reverseDist = ci - reverseWavePos;
      final reverseWave = (reverseProgress > 0 && reverseProgress < 1)
          ? math.exp(-(reverseDist * reverseDist) / (2 * sigma * sigma)) * (1.0 - reverseProgress)
          : 0.0;
      final wave = forwardWave + reverseWave;

      // ── Target scales from raw wave (×2.5 for Flutter's smaller font vs Troika NDC ~97px) ──
      final targetScY = 1.0 + 0.40 * wave;
      final targetScX = 1.0 + 0.07 * wave;

      // ── Per-character scale lerp (Troika: _lerpScY / _lerpScX) ──
      final wordKey = '${wf.wordStart}_$ci';
      double lerpScY = _wordWaves[wordKey] ?? 1.0;
      lerpScY += (targetScY - lerpScY) * scaleLerp;
      _wordWaves[wordKey] = lerpScY;

      double lerpScX = _wordGlows[wordKey] ?? 1.0;
      lerpScX += (targetScX - lerpScX) * scaleLerp;
      _wordGlows[wordKey] = lerpScX;

      // Skip when scale is effectively identity (1.0)
      final doWave = (lerpScY - 1.0).abs() > 0.001 || (lerpScX - 1.0).abs() > 0.001;
      if (!doWave && wave < 0.005) continue;
      anyActive = true;

      final chBox = charBoxes[ci].rect;
      final chCenterX = chBox.center.dx + wx;
      final chBottom = wy + chBox.bottom;

      // Clip to char bounds with upward breathing room (scale grows from bottom)
      final charHeight = chBox.bottom - chBox.top;
      final chRect = Rect.fromLTRB(
        chBox.left + wx, wy + chBox.top - charHeight * 0.2,
        chBox.right + wx, wy + chBox.bottom,
      );

      canvas.save();
      canvas.clipRect(chRect);
      canvas.save();
      canvas.translate(chCenterX, chBottom);
      canvas.scale(lerpScX, lerpScY);
      canvas.translate(-chCenterX, -chBottom);
      canvas.drawParagraph(wf.paragraph, Offset(wx, wy));
      canvas.restore();
      canvas.restore();
    }

    // Cleanup when wave fully decayed (after forward + reverse exit)
    if (!anyActive && playerTime > wf.wordEnd + math.max(1.0, wordDur * 0.5)) {
      _wordWaves.remove(posKey);
      _wordWaves.removeWhere((k, _) => k.startsWith('${wf.wordStart}_'));
      _wordGlows.removeWhere((k, _) => k.startsWith('${wf.wordStart}_'));
    }
  }

  double _clampProgress(double start, double end, [double? effStart]) {
    if (end <= start) return playerTime >= start ? 1.0 : 0.0;
    final es = effStart ?? start;
    if (playerTime <= es) return 0.0;
    return ((playerTime - es) / (end - es)).clamp(0.0, 1.0);
  }

  double _computeEffectiveStart(LyricLine line, int wordIdx, int lineIdx) {
    final w = line.words[wordIdx];
    final end = w.end;
    double effStart = w.start;

    const fillLateMs = 0.012;
    effStart = math.min(end - 0.01, effStart + fillLateMs);

    if (wordIdx == 0 && lineIdx > 0 && lineIdx + 2 < lines.length) {
      final prevEnd = _prevLineEnd(lineIdx);
      if (prevEnd != null) {
        final pause = math.max(0.0, effStart - prevEnd);
        if (pause >= 0.45) {
          final settle = math.min(0.12, 0.03 + pause * 0.16);
          effStart = math.min(end - 0.02, effStart + settle);
        }
      }
    }

    return effStart;
  }

  double? _prevLineEnd(int lineIdx) {
    if (lineIdx <= 0 || lineIdx > lines.length) return null;
    return _lineEnd(lines[lineIdx - 1], lineIdx - 1);
  }

  /// Troika-style 3-dot cue animation.
  ///
  /// Three dots spaced horizontally, filling sequentially as playback
  /// progresses through the cue duration. When all three are filled they
  /// bloom (brief scale-up pulse) then shrink away.
  /// Before track starts: show static dim dots matching Troika waiting state.
  /// [leftX] is the left edge of the text column (matches lyric text alignment).
  void _drawVocalCueDots(Canvas canvas, double leftX, double centerY,
      LyricLine line, double sop, bool isActive) {
    final dotRadius = fontSize * 0.22;
    final dotGap = fontSize * 0.45;
    const exitDur = 0.8;

    final cueStart = line.time;
    final cueEnd = line.end ?? (cueStart + 5.0);
    final totalDur = cueEnd - cueStart;
    if (totalDur <= 0) return;
    final segDur = totalDur / 3.0;
    final exitStart = cueEnd - exitDur;
    final isPostCue = playerTime >= cueEnd;

    // Determine if all dots have filled by the time we enter exit phase.
    final allFilled = 3.0 * (playerTime - cueStart).clamp(0.0, exitDur) / totalDur >= 1.0 ||
        playerTime >= exitStart;

    // Left-aligned: first dot starts at leftX (text column edge).
    final startX = leftX + dotRadius;

    final paint = Paint()..style = PaintingStyle.fill;

    for (int wi = 0; wi < 3; wi++) {
      final segStart = cueStart + wi * segDur;
      final segEnd = segStart + segDur;
      final effectiveEnd = math.min(segEnd, exitStart);

      double dotFill;
      if (playerTime >= effectiveEnd) {
        dotFill = 1.0;
      } else if (playerTime >= segStart) {
        dotFill =
            ((playerTime - segStart) / math.max(0.01, effectiveEnd - segStart))
                .clamp(0.0, 1.0);
      } else {
        dotFill = 0.0;
      }

      final dotX = startX + wi * (dotRadius * 2 + dotGap);

      if (!trackStarted) {
        // ── Static waiting state (matching Troika pre-playback) ──
        paint.color = Colors.white.withValues(alpha: 0.3 * sop);
        canvas.drawCircle(Offset(dotX, centerY), dotRadius, paint);
        continue;
      }

      if (isPostCue) {
        // Fully hidden after cue ends.
        continue;
      }

      if (playerTime >= exitStart && allFilled) {
        // ── Bloom + shrink-away: continuous from filled state ──
        final t =
            ((playerTime - exitStart) / exitDur).clamp(0.0, 1.0); // 0→1
        final opacity = math.max(0.0, 1.0 - t * t);
        // Scale: brief grow (bloom halo feel) then shrink to 0.
        // Peak at t≈0.15, then down to 0.
        const peakT = 0.15;
        double sc;
        if (t < peakT) {
          sc = 1.0 + 0.25 * (t / peakT); // grow to 1.25
        } else {
          sc = 1.25 * (1.0 - (t - peakT) / (1.0 - peakT)); // shrink to 0
        }
        sc = math.max(0.01, sc);

        paint.color = Colors.white.withValues(alpha: opacity * sop);
        canvas.drawCircle(Offset(dotX, centerY), dotRadius * sc, paint);
      } else {
        // ── Fill phase: sequential brightness ramp ──
        // Constant baseline matches unfilled lyric text (0.5).
        // No isActive-dependent jump — avoids blink when line state changes.
        const waitingOp = 0.5;
        double opacity;
        if (dotFill > 0) {
          final brightness = waitingOp + (1.0 - waitingOp) * dotFill;
          opacity = brightness * sop;
        } else {
          opacity = waitingOp * sop;
        }
        paint.color = Colors.white.withValues(alpha: opacity);
        canvas.drawCircle(Offset(dotX, centerY), dotRadius, paint);
      }
    }
  }

  // ── Layout ──

  _LineLayout? _layoutLine(LyricLine line, LineState state, double sop, double maxW, [int lineIdx = 0]) {
    return _layoutLineStatic(line, state, sop, maxW, lineIdx, lines,
        fillColor, unfilledColor, fontSize, featherRatio);
  }

  @override
  bool shouldRepaint(LyricPainter old) =>
      old.playerTime != playerTime || old.lines != lines ||
      old.cOp != cOp || old.cOy != cOy || old.scrollLag != scrollLag ||
      old.smoothedOpacities != smoothedOpacities ||
      old.manualScrollOffset != manualScrollOffset ||
      old.smoothSy != smoothSy || old.isScrolling != isScrolling ||
      old.trackStarted != trackStarted;

  // ── Click-to-seek hit-test ──

  /// Hit-test a tap at [tapPos] in canvas-local coordinates.
  /// Returns the seek time (word.start) if a word was hit, or null.
  /// Render bloom mask — white rects for filled stretch characters.
  /// Used by PictureRecorder → toImage pipeline for separable Gaussian bloom.
  /// Matches main LyricPainter layout so mask aligns pixel-perfect with text.
  static void renderBloomMask({
    required Canvas canvas,
    required Size size,
    required List<LyricLine> lines,
    required double playerTime,
    double fontSize = 28,
    double textMaxWidthRatio = 0.85,
    Map<int, double>? cOp,
    Map<int, double>? cOy,
    Map<int, double>? scrollLag,
    double manualScrollOffset = 0.0,
    double smoothSy = 0.0,
  }) {
    // Black background — transparent means kernel has nothing to blur
    canvas.drawRect(Offset.zero & size, Paint()..color = const Color(0xFF000000));

    if (lines.isEmpty) return;

    final ai = findActiveIdx(lines, playerTime);
    final textMaxW = size.width * textMaxWidthRatio;
    final dx = (size.width - textMaxW) / 2;
    final avgLineH = fontSize * _LINE_SPACING_RATIO + fontSize * 0.4;
    final dynVisible = avgLineH > 0 ? (size.height / avgLineH).ceil() : 7;

    int ws = 0, we = lines.length;
    if (manualScrollOffset.abs() < 0.5) {
      ws = (ai - (dynVisible ~/ 2) - 1).clamp(0, lines.length);
      we = (ws + dynVisible + 3).clamp(0, lines.length);
      if (we - ws < dynVisible) ws = (we - dynVisible).clamp(0, ws);
    }

    // Layout — same pipeline as paint()
    final layouts = <_LineLayout?>[];
    final lineHeights = <double>[];

    for (int i = ws; i < we; i++) {
      final line = lines[i];
      final gap = fontSize * _LINE_SPACING_RATIO;

      if (line.isVocalCue) {
        layouts.add(null);
        lineHeights.add(fontSize + gap);
        continue;
      }
      final state = stateForLine(lines, i, ai, playerTime);
      final targetSop = cOp != null
          ? (cOp[i] ?? stateOpacity(i, ai, state))
          : stateOpacity(i, ai, state);

      // Skip fully-hidden lines (past during auto-scroll → sop=0)
      if (targetSop <= 0.01) {
        layouts.add(null);
        lineHeights.add(fontSize + gap);
        continue;
      }

      final layout = _layoutLineStatic(lines[i], state, targetSop, textMaxW, i, lines,
          const Color(0xFFFFFFFF), const Color(0xFFFFFFFF), fontSize, 0.15);
      layouts.add(layout);
      lineHeights.add(layout?.contentHeight ?? 0 + gap);
    }

    // Position — same as paint(): baseY + smoothSy
    double baseY = 0;

    for (int i = 0; i < layouts.length; i++) {
      final layout = layouts[i];
      final lh = lineHeights[i];
      if (layout == null) { baseY += lh; continue; }

      final lineScreenY = baseY + smoothSy;
      baseY += lh;

      if (lineScreenY < -lh || lineScreenY > size.height + lh) continue;

      // Render stretch word text in white — bloom is letter-shaped, not rectangular
      for (final wf in layout.wordFills) {
        if (!wf.isStretch) continue;

        final wordBox = wf.wordBox;
        final wy = lineScreenY + wordBox.top;
        final wx = dx + wordBox.left;

        // ── Fill sweep: bloom appears gradually as text fills ──
        final wordDur = wf.wordEnd - wf.wordStart;
        final effEnd = wf.wordEnd + wordDur * 0.15;
        final p = playerTime <= wf.effStart ? 0.0
            : playerTime >= effEnd ? 1.0
            : (playerTime - wf.effStart) / (effEnd - wf.effStart);

        // ── Exit fade: bloom turns off like a lamp over 0.5s after word ends ──
        const exitDur = 0.5;
        final exitFade = playerTime > wf.wordEnd
            ? (1.0 - ((playerTime - wf.wordEnd) / exitDur).clamp(0.0, 1.0))
            : 1.0;

        final alpha = p.clamp(0.0, 1.0) * exitFade;
        if (alpha <= 0.01) continue;

        final wordW = wordBox.right - wordBox.left;
        final wordH = wordBox.bottom - wordBox.top;
        final clipRight = p >= 1.0 ? wordW * 1.15 : wordW * p + wordW * 0.15;

        // Build white-text paragraph for this word (letter-shaped bloom source)
        // w900 + slightly larger font = thicker text → more white pixels → brighter blur
        final whitePb = ui.ParagraphBuilder(ui.ParagraphStyle(
          textDirection: TextDirection.ltr, maxLines: 1,
        ));
        whitePb.pushStyle(ui.TextStyle(
          color: const Color(0xFFFFFFFF),
          fontWeight: FontWeight.w900,
          fontSize: wf.fontSize + 2.0,
        ));
        whitePb.addText(wf.wordText);
        whitePb.pop();
        final whitePar = whitePb.build()..layout(ui.ParagraphConstraints(width: textMaxW));

        canvas.save();
        // Clip to fill-sweep region
        canvas.clipRect(Rect.fromLTRB(wx, wy, wx + clipRight, wy + wordH));

        if (alpha < 1.0) {
          // Exit fade: composite layer with reduced opacity
          canvas.saveLayer(
            Rect.fromLTRB(wx, wy, wx + wordW, wy + wordH),
            Paint()..color = const Color(0xFFFFFFFF).withValues(alpha: alpha),
          );
        }
        canvas.drawParagraph(whitePar, Offset(wx, wy));
        if (alpha < 1.0) canvas.restore();

        canvas.restore();
        whitePar.dispose();
      }
    }
  }

  static double? hitTestWord({
    required Size size,
    required List<LyricLine> lines,
    required Offset tapPos,
    required double playerTime,
    double fontSize = 28,
    int visibleLineCount = 7,
    double textMaxWidthRatio = 0.85,
    Map<int, double>? smoothedOpacities,
    double manualScrollOffset = 0.0,
  }) {
    if (lines.isEmpty) return null;

    final ai = findActiveIdx(lines, playerTime);
    final avgLineH = fontSize * _LINE_SPACING_RATIO + fontSize * 0.4;
    final dynVisible = avgLineH > 0 ? (size.height / avgLineH).ceil() : visibleLineCount;

    int ws, we;
    if (manualScrollOffset.abs() > 0.5) {
      ws = 0;
      we = lines.length;
    } else {
      ws = (ai - (dynVisible ~/ 2) - 1).clamp(0, lines.length);
      we = (ws + dynVisible + 3).clamp(0, lines.length);
      if (we - ws < dynVisible) {
        ws = (we - dynVisible).clamp(0, ws);
      }
    }

    final textMaxW = size.width * textMaxWidthRatio;
    final dx = (size.width - textMaxW) / 2;

    // Pass 1: layout all visible lines
    final layouts = <_LineLayout?>[];
    final lineHeights = <double>[];
    final sopTargets = <double>[];

    for (int i = ws; i < we; i++) {
      final line = lines[i];
      final gap = fontSize * _LINE_SPACING_RATIO;

      if (line.isVocalCue) {
        layouts.add(null);
        lineHeights.add(fontSize + gap);
        sopTargets.add(0);
        continue;
      }
      final state = stateForLine(lines, i, ai, playerTime);
      final targetSop = smoothedOpacities != null
          ? (smoothedOpacities[i] ?? stateOpacity(i, ai, state))
          : stateOpacity(i, ai, state);
      sopTargets.add(targetSop);

      final layout = _layoutLineStatic(lines[i], state, targetSop, textMaxW, i, lines,
          const Color(0xFFFFFFFF), const Color(0xFFFFFFFF), fontSize, 0.15);
      layouts.add(layout);
      if (layout != null) {
        final lh = layout.contentHeight + gap;
        lineHeights.add(lh);
      } else {
        lineHeights.add(gap);
      }
    }

    // Active line at exactly _ACTIVE_LINE_Y_RATIO from top. Always.
    double activeTopY = 0;
    for (int i = 0; i < (ai - ws).clamp(0, lineHeights.length); i++) {
      activeTopY += lineHeights[i];
    }
    double sy = size.height * _ACTIVE_LINE_Y_RATIO - activeTopY - manualScrollOffset;

    // Pass 2: hit-test each visible line's words
    double? bestTime;
    double bestDist = double.infinity;

    for (int vi = 0; vi < layouts.length; vi++) {
      final layout = layouts[vi];
      final lh = lineHeights[vi];

      if (layout == null || layout.wordFills.isEmpty) {
        sy += lh;
        continue;
      }

      // Check each word's box
      for (final wf in layout.wordFills) {
        final wordBox = wf.wordBox;
        final wy = sy + wordBox.top;
        final wx = dx + wordBox.left;
        final ww = wordBox.right - wordBox.left;
        final wh = wordBox.bottom - wordBox.top;

        // Check if tap is within or near this word box
        final dxTap = tapPos.dx < wx
            ? wx - tapPos.dx
            : tapPos.dx > wx + ww
                ? tapPos.dx - (wx + ww)
                : 0.0;
        final dyTap = (tapPos.dy - (wy + wh / 2)).abs();
        final dist = dyTap + dxTap * 0.5;

        // Threshold: tap must be within ~1.5x line height vertically
        final lineH = fontSize * 1.3;
        if (dist < bestDist && dyTap < lineH) {
          bestDist = dist;
          bestTime = wf.wordStart;
        }
      }

      sy += lh;
    }

    return bestTime;
  }

  // ── Static layout helper (same as _layoutLine but with explicit color params) ──

  static _LineLayout? _layoutLineStatic(
    LyricLine line,
    LineState state,
    double sop,
    double maxW,
    int lineIdx,
    List<LyricLine> allLines,
    Color fillColor,
    Color unfilledColor,
    double fontSize,
    double featherRatio,
  ) {
    if (line.words.isEmpty) return null;

    final isAdlib = state == LineState.adlib;
    final isPast = state == LineState.past;
    final efs = isAdlib ? fontSize * _FS_AD_RATIO : fontSize;

        final adlibEfs = fontSize * _FS_AD_RATIO;

        final inlineAdlibIdxs = <int>[];
        final mainIdxs = <int>[];
        for (int wi = 0; wi < line.words.length; wi++) {
          if (line.words[wi].flags.contains('adlib')) {
            inlineAdlibIdxs.add(wi);
          } else {
            mainIdxs.add(wi);
          }
        }

        if (!isAdlib && inlineAdlibIdxs.isNotEmpty && mainIdxs.isNotEmpty) {
          return _layoutSplitAdlibs(line, mainIdxs, inlineAdlibIdxs, state, sop, maxW,
              lineIdx, allLines, fillColor, unfilledColor, fontSize, featherRatio, adlibEfs);
        }

        final baseAlpha = isPast ? 0.0 : (_UNFILLED * sop).clamp(0.0, 1.0);
    final fillAlpha = (sop * _FILLED).clamp(0.0, 1.0);

    final fullPb = ui.ParagraphBuilder(ui.ParagraphStyle(
      textDirection: TextDirection.ltr,
    ));
    int charPos = 0;
    final wordSpans = <_WordSpan>[];

    for (int wi = 0; wi < line.words.length; wi++) {
      final w = line.words[wi];
      final fs = FontStyle.normal;

      wordSpans.add(_WordSpan(
        charStart: charPos,
        charEnd: charPos + w.word.length,
        word: w,
        fontStyle: fs,
        wordIndex: wi,
      ));

      final wordBaseEfs = (w.flags.contains('adlib') && !isAdlib) ? fontSize * _FS_AD_RATIO : efs;
      fullPb.pushStyle(ui.TextStyle(
        color: unfilledColor.withValues(alpha: baseAlpha),
        fontWeight: FontWeight.w700, fontStyle: fs, fontSize: wordBaseEfs,
      ));
      fullPb.addText(w.word);
      fullPb.pop();
      charPos += w.word.length;

      if (wi < line.words.length - 1) {
        fullPb.addText(' ');
        charPos += 1;
      }
    }

    final fullPar = fullPb.build()..layout(ui.ParagraphConstraints(width: maxW));
    final contentHeight = fullPar.height;

    final wordFills = <_WordFill>[];

    for (final ws in wordSpans) {
      final w = ws.word;

      final isSungStretch2 = w.flags.contains('stretch');
      final softStretch2 = isSungStretch2 &&
          (w.flags.contains('spoken') || w.word.length <= 1);
      final charStarts = w.charStarts.where((v) => v.isFinite).toList();
      final hasCharTiming2 = charStarts.length == w.word.length && charStarts.length > 1;
      final isCharSplit = charStarts.isNotEmpty &&
          ((isSungStretch2 && !softStretch2) || hasCharTiming2) &&
          w.word.length > 1 && !isAdlib;

      final boxes = fullPar.getBoxesForRange(ws.charStart, ws.charEnd);
      Rect wordBox;
      if (boxes.isNotEmpty) {
        final first = boxes.first;
        final last = boxes.last;
        wordBox = Rect.fromLTRB(first.left, first.top, last.right, last.bottom);
      } else {
        wordBox = Rect.zero;
      }

      final wPb2 = ui.ParagraphBuilder(ui.ParagraphStyle(
        textDirection: TextDirection.ltr, maxLines: 1,
      ));
      final wordFillAlpha2 = (w.flags.contains('stretch'))
          ? sop.clamp(0.0, 1.0)
          : fillAlpha;
      final wordEfs2 = (w.flags.contains('adlib') && !isAdlib) ? fontSize * _FS_AD_RATIO : efs;
      wPb2.pushStyle(ui.TextStyle(
        color: fillColor.withValues(alpha: wordFillAlpha2),
        fontWeight: FontWeight.w700,
        fontStyle: ws.fontStyle,
        fontSize: wordEfs2,
      ));
      wPb2.addText(w.word);
      wPb2.pop();
      final wPar = wPb2.build()..layout(ui.ParagraphConstraints(width: maxW));

      final end = w.end;
      double effStart = w.start;
      const fillLateMs = 0.012;
      effStart = math.min(end - 0.01, effStart + fillLateMs);

      if (ws.wordIndex == 0 && lineIdx > 0 && lineIdx + 2 < allLines.length) {
        double? prevEnd;
        if (lineIdx > 0 && lineIdx <= allLines.length) {
          prevEnd = _lineEndFor(allLines[lineIdx - 1], lineIdx - 1, allLines);
        }
        if (prevEnd != null) {
          final pause = math.max(0.0, effStart - prevEnd);
          if (pause >= 0.45) {
            final settle = math.min(0.12, 0.03 + pause * 0.16);
            effStart = math.min(end - 0.02, effStart + settle);
          }
        }
      }

      final wIsAdlib2 = w.flags.contains('adlib');
      wordFills.add(_WordFill(
        paragraph: wPar,
        wordText: w.word,
        textPos: 0,
        wordLength: w.word.length,
        wordStart: w.start,
        wordEnd: w.end,
        effStart: effStart,
        isCharSplit: isCharSplit,
        isStretch: isSungStretch2,
        hasCharTiming: hasCharTiming2,
        charStarts: charStarts,
        fontSize: efs,
        wordBox: wordBox,
        isAdlib: wIsAdlib2,
      ));
    }

    return _LineLayout(
      paragraph: fullPar,
      wordFills: wordFills,
      contentHeight: contentHeight,
    );
  }

  /// Build split layout: main words in one row, inline adlib words below.
  /// Adlib row: smaller font (_FS_AD_RATIO), darker fill (0.55 alpha), separate paragraph.
  static _LineLayout _layoutSplitAdlibs(
    LyricLine line, List<int> mainIdxs, List<int> adlibIdxs,
    LineState state, double sop, double maxW, int lineIdx,
    List<LyricLine> allLines, Color fillColor, Color unfilledColor,
    double fontSize, double featherRatio, double adlibEfs,
  ) {
    final isPast = state == LineState.past;
    final baseAlpha = isPast ? 0.0 : (_UNFILLED * sop).clamp(0.0, 1.0);
    final fillAlpha = (sop * _FILLED).clamp(0.0, 1.0);
    final adlibFillColor = fillColor.withValues(alpha: 0.55);
    final adlibBaseColor = unfilledColor.withValues(alpha: baseAlpha * 0.6);
    const adlibGap = 4.0;

    // ── Main row: non-adlib words ──
    final mainPb = ui.ParagraphBuilder(ui.ParagraphStyle(textDirection: TextDirection.ltr));
    int charPos = 0;
    final mainSpans = <_WordSpan>[];
    final mainFills = <_WordFill>[];

    for (final wi in mainIdxs) {
      final w = line.words[wi];
      mainSpans.add(_WordSpan(charStart: charPos, charEnd: charPos + w.word.length,
          word: w, fontStyle: FontStyle.normal, wordIndex: wi));
      mainPb.pushStyle(ui.TextStyle(
        color: unfilledColor.withValues(alpha: baseAlpha),
        fontWeight: FontWeight.w700, fontSize: fontSize,
      ));
      mainPb.addText(w.word);
      mainPb.pop();
      charPos += w.word.length;
      if (wi != mainIdxs.last) { mainPb.addText(' '); charPos += 1; }
    }
    final mainPar = mainPb.build()..layout(ui.ParagraphConstraints(width: maxW));

    for (final ws in mainSpans) {
      final w = ws.word;
      final isSung = w.flags.contains('stretch');
      final soft = isSung && (w.flags.contains('spoken') || w.word.length <= 1);
      final cStarts = w.charStarts.where((v) => v.isFinite).toList();
      final hasCT = cStarts.length == w.word.length && cStarts.length > 1;
      final isCharSplit = cStarts.isNotEmpty && ((isSung && !soft) || hasCT) && w.word.length > 1;

      final boxes = mainPar.getBoxesForRange(ws.charStart, ws.charEnd);
      final wBox = boxes.isNotEmpty
          ? Rect.fromLTRB(boxes.first.left, boxes.first.top, boxes.last.right, boxes.last.bottom)
          : Rect.zero;

      final wpb = ui.ParagraphBuilder(ui.ParagraphStyle(textDirection: TextDirection.ltr, maxLines: 1));
      wpb.pushStyle(ui.TextStyle(
        color: fillColor.withValues(alpha: w.flags.contains('stretch') ? sop : fillAlpha),
        fontWeight: FontWeight.w700, fontSize: fontSize,
      ));
      wpb.addText(w.word);
      wpb.pop();
      final wPar = wpb.build()..layout(ui.ParagraphConstraints(width: maxW));

      mainFills.add(_WordFill(
        paragraph: wPar, wordText: w.word, textPos: 0, wordLength: w.word.length,
        wordStart: w.start, wordEnd: w.end, effStart: w.start + 0.012,
        isCharSplit: isCharSplit, isStretch: isSung, hasCharTiming: hasCT,
        charStarts: cStarts, fontSize: fontSize, wordBox: wBox, isAdlib: false,
      ));
    }

    // ── Adlib row: smaller font, darker fill ──
    final adPb = ui.ParagraphBuilder(ui.ParagraphStyle(textDirection: TextDirection.ltr));
    charPos = 0;
    final adSpans = <_WordSpan>[];
    final adFills = <_WordFill>[];

    for (final wi in adlibIdxs) {
      final w = line.words[wi];
      adSpans.add(_WordSpan(charStart: charPos, charEnd: charPos + w.word.length,
          word: w, fontStyle: FontStyle.normal, wordIndex: wi));
      adPb.pushStyle(ui.TextStyle(
        color: adlibBaseColor,
        fontWeight: FontWeight.w700, fontSize: adlibEfs,
      ));
      adPb.addText(w.word);
      adPb.pop();
      charPos += w.word.length;
      if (wi != adlibIdxs.last) { adPb.addText(' '); charPos += 1; }
    }
    final adPar = adPb.build()..layout(ui.ParagraphConstraints(width: maxW));

    double chainEnd = -1.0;
    for (final ws in adSpans) {
      final w = ws.word;
      final boxes = adPar.getBoxesForRange(ws.charStart, ws.charEnd);
      final wBox = boxes.isNotEmpty
          ? Rect.fromLTRB(boxes.first.left, boxes.first.top, boxes.last.right, boxes.last.bottom)
          : Rect.zero;

      final wpb = ui.ParagraphBuilder(ui.ParagraphStyle(textDirection: TextDirection.ltr, maxLines: 1));
      wpb.pushStyle(ui.TextStyle(
        color: adlibFillColor,
        fontWeight: FontWeight.w700, fontSize: adlibEfs,
      ));
      wpb.addText(w.word);
      wpb.pop();
      final wPar = wpb.build()..layout(ui.ParagraphConstraints(width: maxW));

      adFills.add(_WordFill(
        paragraph: wPar, wordText: w.word, textPos: 0, wordLength: w.word.length,
        wordStart: w.start, wordEnd: w.end,
        effStart: math.max(chainEnd, w.start - 0.2),
        isCharSplit: false, isStretch: false, hasCharTiming: false,
        charStarts: [], fontSize: adlibEfs, wordBox: wBox, isAdlib: true,
      ));
      chainEnd = w.end;
    }

    final totalH = mainPar.height + adlibGap + adPar.height;
    return _LineLayout(
      paragraph: mainPar, wordFills: mainFills,
      adlibParagraph: adPar, adlibFills: adFills, adlibGap: adlibGap,
      contentHeight: totalH,
    );
  }
}

// ── Enums & internal classes ──
// (LyricLine, LyricWord, LineState are in models/lyric_models.dart)

class _LineLayout {
  final ui.Paragraph paragraph;           // main words paragraph (base layer)
  final List<_WordFill> wordFills;        // main word fill paragraphs
  final ui.Paragraph? adlibParagraph;     // adlib words paragraph (null if no inline adlibs)
  final List<_WordFill>? adlibFills;      // adlib word fills
  final double adlibGap;                  // gap between main and adlib rows (0 if no adlibs)
  final double contentHeight;             // total rendered height including adlib row
  _LineLayout({required this.paragraph, required this.wordFills,
    this.adlibParagraph, this.adlibFills, this.adlibGap = 0.0,
    required this.contentHeight});
}

class _WordFill {
  final ui.Paragraph paragraph;           // fill-color paragraph (for clip-fill)
  final String wordText;
  final int textPos;
  final int wordLength;
  final double wordStart, wordEnd;
  final double effStart;
  final bool isCharSplit;
  final bool isStretch;                   // P2-4: stretch postroll
  final bool hasCharTiming;               // backend per-char timing available
  final List<double> charStarts;
  final double fontSize;                  // for wave amplitude calc
  final Rect wordBox;                     // position within full-line paragraph
  final bool isAdlib;                     // adlib word (time-based reveal, not fill-sweep)
  _WordFill({
    required this.paragraph, required this.wordText,
    required this.textPos, required this.wordLength,
    required this.wordStart, required this.wordEnd, required this.effStart,
    required this.isCharSplit, required this.isStretch,
    required this.hasCharTiming,
    required this.charStarts, required this.fontSize,
    required this.wordBox,
    this.isAdlib = false,
  });
}

/// Records character-range positions for each word in the full-line paragraph.
class _WordSpan {
  final int charStart, charEnd, wordIndex;
  final LyricWord word;
  final FontStyle fontStyle;
  _WordSpan({required this.charStart, required this.charEnd,
    required this.word, required this.fontStyle, required this.wordIndex});
}

class _CharBox {
  final int index;
  final Rect rect;
  _CharBox({required this.index, required this.rect});
}

// ── (LyricLine, LyricWord, LineState are in models/lyric_models.dart) ──
