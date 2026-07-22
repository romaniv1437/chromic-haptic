// ── Shared lyric data models (used by painter + animator) ──

enum LineState { active, past, future, adlib }

class LyricLine {
  final double time;
  final double? end;
  final String text;
  final List<LyricWord> words;
  final bool isVocalCue;
  final bool adlib;  // line-level adlib flag from JSON (line itself tagged as adlib)

  LyricLine({required this.time, this.end, required this.text,
    required this.words, this.isVocalCue = false, this.adlib = false});

  factory LyricLine.fromJson(Map<String, dynamic> json) {
    final type = json['type'] as String?;
    final vc = type == 'vocal_cue';
    return LyricLine(
      time: (json['time'] as num?)?.toDouble() ?? 0.0,
      end: (json['end'] as num?)?.toDouble(),
      text: json['text'] as String? ?? '',
      words: vc ? [] : (json['words'] as List<dynamic>?)
          ?.map((w) => LyricWord.fromJson(w as Map<String, dynamic>))
          .toList() ?? [],
      isVocalCue: vc,
      adlib: json['adlib'] == true,
    );
  }
}

class LyricWord {
  final String word;
  final double start, end;
  final List<double> charStarts;
  final Set<String> flags;

  LyricWord({required this.word, required this.start, required this.end,
    required this.charStarts, required this.flags});

  factory LyricWord.fromJson(Map<String, dynamic> json) {
    final f = <String>{};
    if (json['sung'] == true) f.add('sung');
    if (json['spoken'] == true) f.add('spoken');
    if (json['whisper'] == true) f.add('whisper');
    if (json['stretch'] == true) f.add('stretch');
    if (json['adlib'] == true) f.add('adlib');
    return LyricWord(
      word: json['word'] as String? ?? '',
      start: (json['start'] as num?)?.toDouble() ?? 0.0,
      end: (json['end'] as num?)?.toDouble() ?? 0.0,
      charStarts: (json['char_starts'] as List<dynamic>?)
          ?.map((e) => (e as num?)?.toDouble() ?? 0.0).toList() ?? [],
      flags: f,
    );
  }
}
