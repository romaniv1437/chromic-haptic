import 'package:flutter_test/flutter_test.dart';
import 'package:chromic_haptic/models/lyric_models.dart';

void main() {
  test('LyricLine.fromJson parses vocal_cue', () {
    final line = LyricLine.fromJson({
      'type': 'vocal_cue', 'time': 5.0, 'text': '',
    });
    expect(line.isVocalCue, true);
    expect(line.time, 5.0);
  });

  test('LyricLine.fromJson parses word with flags', () {
    final line = LyricLine.fromJson({
      'time': 1.0, 'text': 'hello',
      'words': [{'word': 'hello', 'start': 1.0, 'end': 1.5, 'sung': true}],
    });
    expect(line.words.first.word, 'hello');
    expect(line.words.first.flags.contains('sung'), true);
  });
}
