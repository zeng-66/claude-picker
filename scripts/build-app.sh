#!/usr/bin/env bash
# 组装可发布的 ClaudePicker.app（含图标、版本号、降级最低系统版本）
#
# 用法:
#   ./scripts/build-app.sh            # 只在本地 dist/ 里产出
#   ./scripts/build-app.sh --zip      # 额外打 zip
#   ./scripts/build-app.sh --dmg      # 额外打 dmg
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

APP_NAME="ClaudePicker"
DISPLAY_NAME="Claude Code"
BUNDLE_ID="local.zcl.claude-picker"
VERSION="${VERSION:-1.0.0}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
MIN_MACOS="${MIN_MACOS:-14.0}"

DIST="$ROOT/dist"
APP="$DIST/$APP_NAME.app"
CONTENTS="$APP/Contents"

WANT_ZIP=0
WANT_DMG=0
for arg in "$@"; do
  case "$arg" in
    --zip) WANT_ZIP=1 ;;
    --dmg) WANT_DMG=1 ;;
    *) echo "未知参数: $arg" >&2; exit 2 ;;
  esac
done

echo "==> 1/6 构建 release"
swift build -c release

echo "==> 2/6 清理 dist 并组装 bundle"
rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"
cp ".build/release/ClaudeDeck" "$CONTENTS/MacOS/ClaudePicker"

echo "==> 3/6 生成图标"
python3 scripts/make_icon.py "build/icon" >/dev/null
iconutil -c icns "build/icon/AppIcon.iconset" -o "$CONTENTS/Resources/AppIcon.icns"

echo "==> 4/6 写 Info.plist"
cat > "$CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleName</key>
	<string>$APP_NAME</string>
	<key>CFBundleDisplayName</key>
	<string>$DISPLAY_NAME</string>
	<key>CFBundleExecutable</key>
	<string>ClaudePicker</string>
	<key>CFBundleIdentifier</key>
	<string>$BUNDLE_ID</string>
	<key>CFBundleIconFile</key>
	<string>AppIcon</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>$VERSION</string>
	<key>CFBundleVersion</key>
	<string>$BUILD_NUMBER</string>
	<key>CFBundleDevelopmentRegion</key>
	<string>zh_CN</string>
	<key>LSMinimumSystemVersion</key>
	<string>$MIN_MACOS</string>
	<key>LSUIElement</key>
	<false/>
	<key>NSHighResolutionCapable</key>
	<true/>
	<key>NSSupportsAutomaticGraphicsSwitching</key>
	<true/>
	<key>NSHumanReadableCopyright</key>
	<string>ClaudePicker · 本地 Claude Code 会话浏览器</string>
	<key>NSDownloadsFolderUsageDescription</key>
	<string>Claude Code 需要访问「下载」文件夹，以便在其中运行会话、读取项目文件。</string>
	<key>NSDocumentsFolderUsageDescription</key>
	<string>Claude Code 需要访问「文稿」文件夹，以便在其中运行会话、读取项目文件。</string>
	<key>NSDesktopFolderUsageDescription</key>
	<string>Claude Code 需要访问「桌面」文件夹，以便在其中运行会话、读取项目文件。</string>
</dict>
</plist>
PLIST

# 用固定的本地自签证书签名。ad-hoc 签名的 designated requirement 会绑定 cdhash，
# 每次重建 cdhash 都变，导致 TCC（下载/文稿/桌面）授权永远失配、每次都要重新弹窗。
# 用证书签名后 DR 变成 certificate leaf，跨重建稳定，用户点一次「允许」即可长期有效。
SIGN_ID="${SIGN_ID:-ClaudePicker Local Dev}"

echo "==> 5/6 签名（${SIGN_ID}）"
if security find-identity -v -p codesigning 2>/dev/null | grep -qF "$SIGN_ID"; then
	codesign --force --deep --sign "$SIGN_ID" --identifier "$BUNDLE_ID" "$APP"
else
	echo "    !! 未找到证书 ${SIGN_ID}，退回 ad-hoc 签名（TCC 授权无法跨重建保持）"
	codesign --force --deep --sign - --identifier "$BUNDLE_ID" "$APP"
fi
codesign --verify --verbose=2 "$APP" 2>&1 | tail -3

echo "==> 6/6 打包"
if [ "$WANT_ZIP" = "1" ]; then
  ( cd "$DIST" && rm -f "$APP_NAME-$VERSION.zip" && ditto -c -k --sequesterRsrc --keepParent "$APP" "$APP_NAME-$VERSION.zip" )
  echo "    zip: $DIST/$APP_NAME-$VERSION.zip"
fi

if [ "$WANT_DMG" = "1" ]; then
  STAGE="$DIST/dmg-stage"
  rm -rf "$STAGE"; mkdir -p "$STAGE"
  cp -R "$APP" "$STAGE/"
  ln -s /Applications "$STAGE/Applications"
  rm -f "$DIST/$APP_NAME-$VERSION.dmg"
  hdiutil create -quiet -volname "$DISPLAY_NAME" -srcfolder "$STAGE" -ov -format UDZO "$DIST/$APP_NAME-$VERSION.dmg"
  rm -rf "$STAGE"
  echo "    dmg: $DIST/$APP_NAME-$VERSION.dmg"
fi

echo
echo "完成: $APP"
du -sh "$APP"
