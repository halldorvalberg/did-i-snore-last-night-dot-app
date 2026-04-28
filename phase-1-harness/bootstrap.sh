#!/usr/bin/env bash
# THROWAWAY HARNESS - Phase 2 will rebuild this properly.
#
# Bootstrap a runnable Flutter project from this harness skeleton.
#
# Usage (from inside phase-1-harness/):
#   bash bootstrap.sh
#
# What this does:
#   1. Snapshots our hand-written sources to a backup dir.
#   2. Runs `flutter create .` to scaffold the missing platform projects.
#   3. Restores our hand-written sources, overwriting the scaffolded files
#      where they exist (lib/main.dart, AppDelegate.swift, MainActivity.kt,
#      AndroidManifest.xml).
#   4. For Info.plist we DO NOT overwrite — `flutter create .` produces a
#      complete Info.plist and ours is only a snippet. The script prints
#      instructions so you can merge by hand.
#   5. Runs `flutter pub get`.

set -euo pipefail

if ! command -v flutter >/dev/null 2>&1; then
    echo "error: flutter is not on PATH"
    echo "install Flutter >= 3.22 first: https://docs.flutter.dev/get-started/install"
    exit 1
fi

if [[ ! -f pubspec.yaml ]]; then
    echo "error: run bootstrap.sh from inside phase-1-harness/"
    exit 1
fi

ORG="app.didisnorelastnight.smoke"
PROJECT_NAME="phase_1_harness"

BACKUP_DIR=".bootstrap-backup"
echo "==> snapshotting hand-written sources to $BACKUP_DIR"
rm -rf "$BACKUP_DIR"
mkdir -p "$BACKUP_DIR"
cp -R lib "$BACKUP_DIR/lib"
cp -R tools "$BACKUP_DIR/tools"
[[ -d android ]] && cp -R android "$BACKUP_DIR/android"
[[ -d ios ]] && cp -R ios "$BACKUP_DIR/ios"
cp pubspec.yaml "$BACKUP_DIR/pubspec.yaml"

echo "==> running flutter create"
flutter create . \
    --org "$ORG" \
    --project-name "$PROJECT_NAME" \
    --platforms=android,ios \
    --overwrite

echo "==> restoring hand-written sources"
# Lib + tools: full overwrite (the harness owns these directories).
rm -rf lib tools
cp -R "$BACKUP_DIR/lib" lib
cp -R "$BACKUP_DIR/tools" tools
cp "$BACKUP_DIR/pubspec.yaml" pubspec.yaml

# Android manifest: replace the scaffolded one. flutter_background_service's
# manifest merger needs our `tools:replace` to win.
cp "$BACKUP_DIR/android/app/src/main/AndroidManifest.xml" \
   android/app/src/main/AndroidManifest.xml

# Network security config.
mkdir -p android/app/src/main/res/xml
cp "$BACKUP_DIR/android/app/src/main/res/xml/network_security_config.xml" \
   android/app/src/main/res/xml/network_security_config.xml

# Kotlin MainActivity. The path includes the application id; flutter create
# generated one at the same path.
KOTLIN_PATH="android/app/src/main/kotlin/app/didisnorelastnight/smoke/phase_1_harness/MainActivity.kt"
mkdir -p "$(dirname "$KOTLIN_PATH")"
cp "$BACKUP_DIR/$KOTLIN_PATH" "$KOTLIN_PATH"

# iOS AppDelegate: replace the scaffolded one (it's just GeneratedPluginRegistrant).
cp "$BACKUP_DIR/ios/Runner/AppDelegate.swift" ios/Runner/AppDelegate.swift

echo
echo "==> Info.plist is NOT auto-merged (our file is a snippet)."
echo "    Open ios/Runner/Info.plist and merge in these keys from"
echo "    $BACKUP_DIR/ios/Runner/Info.plist:"
echo "      - NSMicrophoneUsageDescription"
echo "      - UIBackgroundModes (must include 'audio')"
echo "      - NSAppTransportSecurity / NSAllowsArbitraryLoads = false"
echo

echo "==> flutter pub get"
flutter pub get

echo
echo "==> bootstrap complete."
echo "    next:"
echo "      - merge Info.plist as described above"
echo "      - on Android: ensure minSdkVersion >= 24 in android/app/build.gradle"
echo "        (foreground-service-microphone requires API 28+, but record/"
echo "         permission_handler bumps minSdk anyway)"
echo "      - flutter run --release"
