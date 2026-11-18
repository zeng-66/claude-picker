#!/usr/bin/env bash
# 组装可发布的 ClaudePicker.app（含图标、版本号、降级最低系统版本）
#
# 用法:
#   ./scripts/build-app.sh            # 只在本地 dist/ 里产出
#   ./scripts/build-app.sh --zip      # 额外打 zip
#   ./scripts/build-app.sh --dmg      # 额外打 dmg
#   ./scripts/build-app.sh --dev      # 调试包：dist-dev/ClaudePickerDev.app，独立 bundle id 与数据目录，
#                                     # 不会顶掉正在使用的正式版（调试时一律用它）
#   ./scripts/build-app.sh --test     # 测试包：dist-test/ClaudePickerTest.app，数据目录同调试包，可与正式版并存
#   ./scripts/build-app.sh --with-chat  # 打入图形聊天（Swttch backend/webview 产物 + Node 运行时）
#
# 图形聊天相关环境变量:
#   SWTTCH_DIR   上游源码目录，需先构建 backend/dist 与 webview/dist（默认 ~/project/swttch）
#   NODE_BIN     要打包的 node 可执行文件（默认 PATH 里的 node，再退回 nvm 最新版）
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

WANT_ZIP=0
WANT_DMG=0
WANT_CHAT=0
for arg in "$@"; do
  case "$arg" in
    --zip) WANT_ZIP=1 ;;
    --dmg) WANT_DMG=1 ;;
    --dev)
      APP_NAME="ClaudePickerDev"
      DISPLAY_NAME="Claude Code Dev"
      BUNDLE_ID="local.zcl.claude-picker.dev"
      DIST="$ROOT/dist-dev"
      ;;
    --test)
      APP_NAME="ClaudePickerTest"
      DISPLAY_NAME="Claude Code Test"
      # 以 .dev 结尾：沿用调试包的独立数据目录，不碰正式版的 tree.json / settings.json
      BUNDLE_ID="local.zcl.claude-picker.test.dev"
      DIST="$ROOT/dist-test"
      ;;
    --with-chat) WANT_CHAT=1 ;;
    *) echo "未知参数: $arg" >&2; exit 2 ;;
  esac
done

APP="$DIST/$APP_NAME.app"
CONTENTS="$APP/Contents"

echo "==> 1/7 构建 release"
swift build -c release

echo "==> 2/7 构建前端（Web → Contents/Resources/web）"
if [[ ! -d Web/node_modules ]]; then
    echo "    Web/node_modules 不存在，先装一次依赖"
    (cd Web && npm install --no-audit --no-fund)
fi
(cd Web && npm run build)

echo "==> 3/7 清理 dist 并组装 bundle"
rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"
cp ".build/release/ClaudeDeck" "$CONTENTS/MacOS/$APP_NAME"
cp -R Web/dist "$CONTENTS/Resources/web"
BUILD_COMMIT="$(git rev-parse HEAD)"
BUILD_DIRTY="false"
if [[ -n "$(git status --porcelain --untracked-files=normal)" ]]; then BUILD_DIRTY="true"; fi

if [ "$WANT_CHAT" = "1" ]; then
  echo "    打入图形聊天资源"
  SWTTCH_DIR="${SWTTCH_DIR:-$HOME/project/swttch}"
  for f in backend/dist/backend.mjs webview/dist/index.html; do
    [ -f "$SWTTCH_DIR/$f" ] || { echo "缺少 $SWTTCH_DIR/$f，请先在上游执行 be-build / wv-build" >&2; exit 1; }
  done
  if [ -z "${NODE_BIN:-}" ]; then
    NODE_BIN="$(command -v node || true)"
    [ -n "$NODE_BIN" ] || NODE_BIN="$(ls -d "$HOME"/.nvm/versions/node/*/bin/node 2>/dev/null | sort -V | tail -1)"
  fi
  [ -x "$NODE_BIN" ] || { echo "找不到 node，请设置 NODE_BIN" >&2; exit 1; }
  RES="$CONTENTS/Resources"
  mkdir -p "$RES/swttch/backend" "$RES/swttch/webview" "$RES/node/bin"
  # 只拷运行产物，不带 sourcemap 与 node_modules（backend 已由 esbuild 打成单文件）
  rsync -a --exclude '*.map' "$SWTTCH_DIR/backend/dist" "$RES/swttch/backend/"
  rsync -a "$SWTTCH_DIR/webview/dist" "$RES/swttch/webview/"
  cp "$SWTTCH_DIR/LICENSE" "$RES/swttch/LICENSE"
  ( cd "$SWTTCH_DIR" && git rev-parse HEAD 2>/dev/null ) > "$RES/swttch/UPSTREAM_REVISION" || true
  cp "$NODE_BIN" "$RES/node/bin/node"
  NODE_ROOT="$(cd "$(dirname "$NODE_BIN")/.." && pwd)"
  [ -f "$NODE_ROOT/LICENSE" ] && cp "$NODE_ROOT/LICENSE" "$RES/node/LICENSE"
  echo "    swttch: $(cat "$RES/swttch/UPSTREAM_REVISION" 2>/dev/null) · node: $("$NODE_BIN" -v)"
fi

echo "==> 4/7 生成图标"
python3 scripts/make_icon.py "build/icon" >/dev/null
iconutil -c icns "build/icon/AppIcon.iconset" -o "$CONTENTS/Resources/AppIcon.icns"

echo "==> 5/7 写 Info.plist"
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
	<string>$APP_NAME</string>
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
	<key>ClaudePickerCommit</key>
	<string>$BUILD_COMMIT</string>
	<key>ClaudePickerDirty</key>
	<string>$BUILD_DIRTY</string>
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

echo "==> 6/7 签名（${SIGN_ID}）"
if ! security find-identity -v -p codesigning 2>/dev/null | grep -qF "$SIGN_ID"; then
	echo "    !! 未找到证书 ${SIGN_ID}，退回 ad-hoc 签名（TCC 授权无法跨重建保持）"
	SIGN_ID="-"
fi
# Resources 里的 node 不在 --deep 的扫描范围，先单独签
if [ -f "$CONTENTS/Resources/node/bin/node" ]; then
	codesign --force --sign "$SIGN_ID" "$CONTENTS/Resources/node/bin/node"
fi
codesign --force --deep --sign "$SIGN_ID" --identifier "$BUNDLE_ID" "$APP"
codesign --verify --verbose=2 "$APP" 2>&1 | tail -3

echo "==> 7/7 打包"
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
