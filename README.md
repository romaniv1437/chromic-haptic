# Chromic Haptic Player

> Flutter app that renders synced lyrics with per-character GPU fill + beat-synced haptic vibration. Connects to Modal backend for Whisper alignment and haptic beat detection.

https://github.com/user-attachments/assets/a0427ab0-477a-4e54-bd7d-9fcb96cb85cc

## Requirements

- **Flutter SDK** (`brew install --cask flutter`)
- **Android SDK** (via Android Studio)
- **Android phone** for vibration testing (emulator can't vibrate)

## Quick Start

```zsh
cd chromic-haptic
flutter pub get
flutter run          # with phone connected via USB (Debug Mode)
flutter build apk    # build APK
```

## App Structure

```
lib/
├── main.dart              # App entry: URL input + player
├── main_mobile.dart       # Mobile-specific entry
├── engine/
│   └── haptic_engine.dart # Beat-synced vibration engine
├── models/
│   └── lyric_models.dart  # Data models
├── services/
│   ├── local_cache.dart   # JSON caching
│   └── upload_service.dart# Modal upload + poll
└── widgets/
    ├── lyric_painter.dart  # GPU per-character fill
    ├── haptic_timeline.dart# Vibration timeline UI
    └── bloom_widget.dart   # Bloom shader widget
shaders/
├── bloom.frag
├── green_test.frag
└── char_glow.frag
```

## How It Works

1. User pastes URL → POST to Modal backend (~5 min)
2. Modal: demucs → whisper → haptic.py → `haptics` JSON
3. Flutter caches JSON, plays audio via `just_audio`, renders lyrics
4. `HapticEngine` checks position 50x/sec → vibrates on beats
5. Fragment shaders fill characters with green glow, letter by letter

## Build Release APK

```zsh
keytool -genkey -v -keystore ~/chromic-keystore.jks \
  -keyalg RSA -keysize 2048 -validity 10000 -alias chromic
flutter build apk --release
# APK: build/app/outputs/flutter-apk/app-release.apk
```
