#!/bin/zsh
# 打包拖拽安装式 DMG：左侧 App 图标、右侧「应用程序」替身，打开即可拖入安装。
# 用法: scripts/package-dmg.sh <NotchDeck.app 路径> <输出 dmg 路径>
#
# 优先用 create-dmg（brew）排版图标与替身；Finder 自动化失败时降级为
# hdiutil + 手动 /Applications 替身——布局不排版，但拖拽目标仍然存在。
set -euo pipefail

if [ $# -ne 2 ]; then
  echo "用法: $0 <NotchDeck.app 路径> <输出 dmg 路径>" >&2
  exit 1
fi

app_path=$(cd "$1:h" && pwd)/"$1:t"   # 转绝对路径
output=$2

if [ ! -d "$app_path" ]; then
  echo "未找到 app: $app_path" >&2
  exit 1
fi

staging=$(mktemp -d "${TMPDIR:-/tmp}notchdeck-dmg.XXXXXX")
trap 'rm -rf "$staging"' EXIT
cp -R "$app_path" "$staging/NotchDeck.app"

if command -v create-dmg >/dev/null && \
   create-dmg \
     --volname "NotchDeck" \
     --window-size 520 300 \
     --icon-size 100 \
     --icon "NotchDeck.app" 150 150 \
     --app-drop-link 370 150 \
     --hide-extension "NotchDeck.app" \
     "$output" "$staging"; then
  echo "已生成排版式 DMG: $output"
else
  echo "create-dmg 不可用或失败，降级为 hdiutil + 应用程序替身" >&2
  ln -s /Applications "$staging/Applications"
  rm -f "$output"
  hdiutil create -volname NotchDeck -srcfolder "$staging" -ov -format UDZO "$output" >/dev/null
  echo "已生成基础 DMG: $output"
fi

ls -lh "$output"
