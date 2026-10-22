#!/bin/bash
# MyTube 빌드 → ~/Applications/MyTube.app 생성
# (외장하드가 exFAT이라 앱 서명이 안 될 수 있어서, 앱은 내장 디스크에 만듦)
set -euo pipefail
cd "$(dirname "$0")"

echo "▶ 빌드 중..."
swift build -c release

APP="$HOME/Applications/MyTube.app"
echo "▶ 앱 묶는 중: $APP"
pkill -x MyTube 2>/dev/null || true
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/MyTube "$APP/Contents/MacOS/MyTube"
cp Info.plist "$APP/Contents/Info.plist"
# 아이콘이 있을 때만 넣음 (scripts/make_icon.swift로 만듦)
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

echo "▶ 서명 중 (내 Mac 전용)"
# 개인용 서명 (다시 빌드하면 macOS가 새 앱으로 보고 권한을 다시 요청함)
codesign --force --sign - "$APP"

echo "✅ 완료: $APP"

echo "▶ 앱 실행"
open "$APP"
