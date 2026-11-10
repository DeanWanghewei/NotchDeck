#!/usr/bin/env bash
# NotchDeck 回归验证脚本
#
# 用法：
#   scripts/verify.sh            # 沙箱 / 受限环境：DerivedData 放仓库内，宏插件关沙箱，xctest 直跑
#   scripts/verify.sh --full     # 完整 xcodebuild test（需要能写 ~/Library/Developer/Xcode/DerivedData 并分配 pty）
#
# 背景见 docs/macos-notes.md「受限运行环境」：受限环境里标准命令会因环境而非代码失败，
# 三处偏差分别是 DerivedData 不可写、Swift 宏插件套二层沙箱、测试运行器需要 pty。
set -euo pipefail

cd "$(dirname "$0")/.."

if [[ "${1:-}" == "--full" ]]; then
    xcodegen generate
    exec xcodebuild -project NotchDeck.xcodeproj -scheme NotchDeck \
        -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO test
fi

xcodegen generate
xcodebuild -project NotchDeck.xcodeproj -scheme NotchDeck \
    -destination 'platform=macOS' \
    -derivedDataPath build/DerivedData \
    CODE_SIGNING_ALLOWED=NO \
    OTHER_SWIFT_FLAGS='$(inherited) -disable-sandbox' \
    build-for-testing

exec xcrun xctest -XCTest All build/DerivedData/Build/Products/Debug/NotchDeckTests.xctest
