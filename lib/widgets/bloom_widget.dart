import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'lyric_painter.dart';
import '../models/lyric_models.dart';

/// 🟢 Green diagnostic shader overlay — verifies FragmentProgram works on device.
/// Shows a pulsing green vignette. If this renders, shaders are working.
class GreenShaderTest extends StatefulWidget {
  const GreenShaderTest({super.key});
  @override
  State<GreenShaderTest> createState() => _GreenShaderTestState();
}

class _GreenShaderTestState extends State<GreenShaderTest>
    with SingleTickerProviderStateMixin {
  ui.FragmentProgram? _program;
  late final Ticker _ticker;
  double _time = 0;

  @override
  void initState() {
    super.initState();
    _loadShader();
    _ticker = createTicker((elapsed) {
      setState(() => _time = elapsed.inMicroseconds / 1000000.0);
    })..start();
  }

  Future<void> _loadShader() async {
    try {
      final p = await ui.FragmentProgram.fromAsset('shaders/green_test.frag');
      if (mounted) setState(() => _program = p);
    } catch (e) {
      debugPrint('[GREEN_SHADER] ❌ Compile failed: $e');
    }
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = _program;
    if (p == null) {
      return const SizedBox(
        width: 40, height: 40,
        child: DecoratedBox(
          decoration: BoxDecoration(color: Colors.red, borderRadius: BorderRadius.all(Radius.circular(8))),
          child: Center(child: Text('?', style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold))),
        ),
      );
    }
    return SizedBox(
      width: 40, height: 40,
      child: CustomPaint(
        painter: _GreenPainter(p, _time),
      ),
    );
  }
}

class _GreenPainter extends CustomPainter {
  final ui.FragmentProgram program;
  final double time;
  _GreenPainter(this.program, this.time);

  @override
  void paint(Canvas canvas, Size size) {
    final shader = program.fragmentShader();
    shader.setFloat(0, time);
    shader.setFloat(1, size.width);
    shader.setFloat(2, size.height);
    canvas.drawRect(Offset.zero & size, Paint()..shader = shader);
  }

  @override
  bool shouldRepaint(_GreenPainter old) => old.time != time;
}

/// Bloom compositor — draws blurred bloom on top of scene using fragment shader.
/// Shader: Gaussian blur of white-on-black mask → soft glow halo.
/// Output: premultiplied alpha so srcOver adds bloom where bright, keeps scene where dark.
class BloomPainter extends CustomPainter {
  final ui.Image maskImage;
  final ui.FragmentProgram program;
  final double sigma;
  final double strength;

  BloomPainter({
    required this.maskImage,
    required this.program,
    this.sigma = 6.0,
    this.strength = 2.0,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final shader = program.fragmentShader();
    shader.setImageSampler(0, maskImage);
    shader.setFloat(1, maskImage.width.toDouble());
    shader.setFloat(2, maskImage.height.toDouble());
    shader.setFloat(3, sigma);
    shader.setFloat(4, strength);

    canvas.drawRect(
      Offset.zero & size,
      Paint()
        ..shader = shader
        ..blendMode = BlendMode.plus,
    );
  }

  @override
  bool shouldRepaint(BloomPainter old) =>
      old.maskImage != maskImage ||
      old.sigma != sigma ||
      old.strength != strength;
}

/// Renders white rects for fully-filled characters (fill >= 90%).
/// Delegates to [LyricPainter.renderBloomMask] for layout + fill logic.
class FilledCharsMaskPainter extends CustomPainter {
  final List<LyricLine> lines;
  final double playerTime;
  final double fontSize;
  final double textMaxWidthRatio;
  final Map<int, double>? cOp;
  final double manualScrollOffset;
  final double smoothSy;

  FilledCharsMaskPainter({
    required this.lines,
    required this.playerTime,
    this.fontSize = 28,
    this.textMaxWidthRatio = 0.85,
    this.cOp,
    this.manualScrollOffset = 0.0,
    this.smoothSy = 0.0,
  });

  @override
  void paint(Canvas canvas, Size size) {
    LyricPainter.renderBloomMask(
      canvas: canvas,
      size: size,
      lines: lines,
      playerTime: playerTime,
      fontSize: fontSize,
      textMaxWidthRatio: textMaxWidthRatio,
      cOp: cOp,
      manualScrollOffset: manualScrollOffset,
      smoothSy: smoothSy,
    );
  }

  @override
  bool shouldRepaint(FilledCharsMaskPainter old) =>
      old.playerTime != playerTime ||
      old.lines != lines ||
      old.smoothSy != smoothSy ||
      old.manualScrollOffset != manualScrollOffset ||
      old.cOp != cOp;
}

/// Bloom overlay — renders stretch-word glow via multi-scale Gaussian blur.
///
/// Pipeline: PictureRecorder → toImage (mask) → bloom.frag (multi-scale blur)
/// → BlendMode.plus composite over scene.
///
/// One-frame delay for mask capture (same as UnrealBloomPass rendering
/// previous frame's render target).
class LyricBloomOverlay extends StatefulWidget {
  final List<LyricLine> lines;
  final double playerTime;
  final ui.FragmentProgram bloomProgram;
  final double fontSize;
  final double textMaxWidthRatio;
  final Map<int, double>? cOp;
  final double manualScrollOffset;
  final double smoothSy;
  final double sigma;
  final double strength;

  const LyricBloomOverlay({
    super.key,
    required this.lines,
    required this.playerTime,
    required this.bloomProgram,
    this.fontSize = 28,
    this.textMaxWidthRatio = 0.85,
    this.cOp,
    this.manualScrollOffset = 0.0,
    this.smoothSy = 0.0,
    this.sigma = 6.0,
    this.strength = 2.0,
  });

  @override
  State<LyricBloomOverlay> createState() => _LyricBloomOverlayState();
}

class _LyricBloomOverlayState extends State<LyricBloomOverlay> {
  ui.Image? _maskImage;
  Size? _maskSize;
  bool _dirty = true;
  bool _rendering = false;

  @override
  void didUpdateWidget(LyricBloomOverlay old) {
    super.didUpdateWidget(old);
    if (old.playerTime != widget.playerTime ||
        old.smoothSy != widget.smoothSy ||
        old.manualScrollOffset != widget.manualScrollOffset ||
        old.cOp != widget.cOp ||
        old.lines != widget.lines) {
      _dirty = true;
    }
  }

  Future<void> _renderMask(Size size) async {
    if (_rendering || size.width < 1 || size.height < 1) return;
    _rendering = true;

    try {
      final recorder = ui.PictureRecorder();
      final maskCanvas = Canvas(recorder);
      LyricPainter.renderBloomMask(
        canvas: maskCanvas,
        size: size,
        lines: widget.lines,
        playerTime: widget.playerTime,
        fontSize: widget.fontSize,
        textMaxWidthRatio: widget.textMaxWidthRatio,
        cOp: widget.cOp,
        manualScrollOffset: widget.manualScrollOffset,
        smoothSy: widget.smoothSy,
      );
      final picture = recorder.endRecording();
      final img = await picture.toImage(size.width.toInt(), size.height.toInt());
      picture.dispose();

      if (!mounted) {
        img.dispose();
        return;
      }
      _maskImage?.dispose();
      _maskImage = img;
      _maskSize = size;
      _dirty = false;
      if (mounted) setState(() {});
    } catch (e) {
      debugPrint('[BLOOM] Mask render failed: $e');
    } finally {
      _rendering = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = Size(constraints.maxWidth, constraints.maxHeight);
        if (_dirty || _maskSize != size) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) _renderMask(size);
          });
        }

        final img = _maskImage;
        if (img == null) return const SizedBox.shrink();

        return CustomPaint(
          size: size,
          painter: BloomPainter(
            maskImage: img,
            program: widget.bloomProgram,
            sigma: widget.sigma,
            strength: widget.strength,
          ),
        );
      },
    );
  }

  @override
  void dispose() {
    _maskImage?.dispose();
    super.dispose();
  }
}
