#!/bin/bash
# 把 Swift Package 编译产物打包成一个真正的 .app（这个项目没有 Xcode 工程文件，
# 全靠 swift build + 手工拼装 bundle，这个脚本就是把手工步骤自动化）。
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="frp 隧道面板"
BUNDLE_ID="com.user.frp-panel-app"
DEST="/Applications/${APP_NAME}.app"

echo "==> swift build (release)"
swift build -c release

echo "==> 生成图标 (.icns)"
TMP_ICON_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_ICON_DIR"' EXIT

CHROME_BIN="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
if command -v rsvg-convert >/dev/null 2>&1; then
  rsvg-convert -w 1024 -h 1024 icon.svg -o "$TMP_ICON_DIR/icon_1024.png"
elif [ -x "$CHROME_BIN" ]; then
  # 路径带空格，必须整体当一个参数传给 --screenshot 之外的可执行文件本身，
  # 拼字符串再 eval 会被空格错误分词，这里直接用数组式调用规避
  "$CHROME_BIN" --headless --disable-gpu \
    --screenshot="$TMP_ICON_DIR/icon_1024.png" --window-size=1024,1024 \
    --default-background-color=00000000 --hide-scrollbars "file://$(pwd)/icon.svg"
else
  echo "需要 rsvg-convert 或 Chrome 来把 icon.svg 渲染成 PNG，两者都没找到。" >&2
  echo "装一个：brew install librsvg" >&2
  exit 1
fi

mkdir -p "$TMP_ICON_DIR/AppIcon.iconset"
for s in 16 32 128 256 512; do
  sips -z $s $s "$TMP_ICON_DIR/icon_1024.png" --out "$TMP_ICON_DIR/AppIcon.iconset/icon_${s}x${s}.png" >/dev/null
  d=$((s * 2))
  sips -z $d $d "$TMP_ICON_DIR/icon_1024.png" --out "$TMP_ICON_DIR/AppIcon.iconset/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$TMP_ICON_DIR/AppIcon.iconset" -o "$TMP_ICON_DIR/AppIcon.icns"

echo "==> 生成菜单栏图标 (多分辨率 tiff)"
if command -v rsvg-convert >/dev/null 2>&1; then
  rsvg-convert -w 40 -h 22 menubar-icon.svg -o "$TMP_ICON_DIR/menubar_1x.png"
  rsvg-convert -w 80 -h 44 menubar-icon.svg -o "$TMP_ICON_DIR/menubar_2x.png"
else
  "$CHROME_BIN" --headless --disable-gpu \
    --screenshot="$TMP_ICON_DIR/menubar_1x.png" --window-size=40,22 \
    --default-background-color=00000000 --hide-scrollbars "file://$(pwd)/menubar-icon.svg"
  "$CHROME_BIN" --headless --disable-gpu \
    --screenshot="$TMP_ICON_DIR/menubar_2x.png" --window-size=80,44 \
    --default-background-color=00000000 --hide-scrollbars "file://$(pwd)/menubar-icon.svg"
fi
tiffutil -cathidpicheck "$TMP_ICON_DIR/menubar_1x.png" "$TMP_ICON_DIR/menubar_2x.png" -out "$TMP_ICON_DIR/MenuBarIcon.tiff" >/dev/null

echo "==> 组装 .app bundle"
rm -rf "$DEST"
mkdir -p "$DEST/Contents/MacOS" "$DEST/Contents/Resources"
cp .build/release/FrpPanel "$DEST/Contents/MacOS/FrpPanel"
cp "$TMP_ICON_DIR/AppIcon.icns" "$DEST/Contents/Resources/AppIcon.icns"
cp "$TMP_ICON_DIR/MenuBarIcon.tiff" "$DEST/Contents/Resources/MenuBarIcon.tiff"

cat > "$DEST/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleExecutable</key>
    <string>FrpPanel</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleVersion</key>
    <string>1.0</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>LSUIElement</key>
    <true/>
    <key>NSAppTransportSecurity</key>
    <dict>
        <key>NSAllowsLocalNetworking</key>
        <true/>
    </dict>
</dict>
</plist>
PLIST

echo "==> 签名（本地 ad-hoc 签名，仅供本机运行，不做分发公证）"
codesign --force --deep --sign - "$DEST"

echo "==> 完成：$DEST"
