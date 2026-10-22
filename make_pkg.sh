#!/bin/bash
# MyTube 설치 파일 만들기 → dist/MyTube-<버전>.pkg
# 설치하면 /Applications/MyTube.app 에 들어가고 자동 실행됨
set -euo pipefail
# ._ 숨김 파일이 설치 파일에 섞이지 않게 함
export COPYFILE_DISABLE=1
cd "$(dirname "$0")"

VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Info.plist)
IDENTIFIER=com.local.MyTube

echo "▶ 빌드 중..."
swift build -c release

# 외장하드(exFAT)는 숨김 파일(._*)이 생겨서, 내장 디스크 임시 폴더에서 작업
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
ROOT="$WORK/root"
APP="$ROOT/Applications/MyTube.app"

echo "▶ 앱 묶는 중"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$WORK/scripts"
cp .build/release/MyTube "$APP/Contents/MacOS/MyTube"
cp Info.plist "$APP/Contents/Info.plist"
# 아이콘이 있을 때만 넣음 (scripts/make_icon.swift로 만듦)
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp scripts/postinstall "$WORK/scripts/postinstall"
chmod 755 "$WORK/scripts/postinstall"
# 외장하드(exFAT)는 모든 파일이 rwx------ 라서, 설치 후 사용자가 못 읽는 문제 방지
# (폴더·실행 파일 755, 나머지 644)
chmod -R u=rwX,go=rX "$ROOT"
chmod 755 "$APP/Contents/MacOS/MyTube"
xattr -cr "$ROOT"
# 개인용 서명 (다시 빌드하면 macOS가 새 앱으로 보고 권한을 다시 요청함)
codesign --force --sign - "$APP"
xattr -cr "$ROOT"

# 같은 앱이 다른 위치(~/Applications 등)에 있어도 항상 /Applications 에 설치되게 함
pkgbuild --analyze --root "$ROOT" "$WORK/component.plist" >/dev/null
/usr/libexec/PlistBuddy -c "Add :0:BundleIsRelocatable bool false" "$WORK/component.plist"

echo "▶ 설치 파일 만드는 중"
# macOS 27의 pkgbuild는 항상 "write: Permission denied"를 출력함 (결과물엔 영향 없음) → 그 줄만 숨김
pkgbuild --root "$ROOT" \
         --component-plist "$WORK/component.plist" \
         --scripts "$WORK/scripts" \
         --identifier "$IDENTIFIER" \
         --version "$VERSION" \
         --install-location / \
         "$WORK/component.pkg" >/dev/null 2>"$WORK/pkgbuild.err" || { cat "$WORK/pkgbuild.err" >&2; exit 1; }
grep -v '^write: Permission denied$' "$WORK/pkgbuild.err" >&2 || true

productbuild --package "$WORK/component.pkg" "$WORK/final.pkg" >/dev/null

# 완성된 파일만 외장하드로 복사 (확장 속성은 빼고)
mkdir -p dist
OUT="dist/MyTube-$VERSION.pkg"
rm -f "$OUT"
cp -X "$WORK/final.pkg" "$OUT"

# 이전 버전 설치 파일은 지우고 최신 파일 하나만 남김 (외장하드 숨김 파일 ._* 포함)
for old in dist/MyTube-*.pkg; do
    if [ "$old" != "$OUT" ]; then
        echo "▶ 이전 파일 삭제: $old"
        rm -f "$old"
    fi
done
rm -f dist/._*

echo "✅ 완료: $(pwd)/$OUT"

# 구글 드라이브의 "MyTube 배포판" 폴더에도 넣음 (Google Drive 데스크톱 앱이 있을 때, 최근 3개만 남김)
DRIVE=""
for d in "$HOME"/Library/CloudStorage/GoogleDrive-*; do
    for root in "$d/My Drive" "$d/내 드라이브"; do
        [ -d "$root" ] && DRIVE="$root" && break 2
    done
done
if [ -n "$DRIVE" ]; then
    # 폴더를 다른 곳(예: AI작업)으로 옮겼을 수 있으니 먼저 찾고, 없을 때만 AI작업 아래에 만듦
    DEST=$(find "$DRIVE" -maxdepth 3 -type d -name "MyTube 배포판" 2>/dev/null | head -1)
    [ -z "$DEST" ] && DEST="$DRIVE/AI작업/MyTube 배포판"
    mkdir -p "$DEST"
    cp -X "$OUT" "$DEST/"
    ls -t "$DEST"/MyTube-*.pkg 2>/dev/null | tail -n +4 | while read -r old; do rm -f "$old"; done
    echo "☁️ 구글 드라이브에 올림: $DEST/$(basename "$OUT")"
else
    echo "☁️ 구글 드라이브 폴더가 없어서 건너뜀 (Google Drive 데스크톱 앱을 설치하면 자동으로 올라가요)"
fi
