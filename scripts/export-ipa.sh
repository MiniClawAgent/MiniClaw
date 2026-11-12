#!/bin/bash
# MiniClaw 一键打包脚本(2026-08-13)
# 背景:Xcode 26.6 归档服务对本项目不再写 xcarchive/Info.plist 的 ApplicationProperties,
#       导致 Organizer 显示 "Generic Xcode Archive"、Version 空白、Distribute 只剩 Custom,
#       命令行 -exportArchive 也拒绝(method 列表为空)。本脚本在 archive 后自动补全该键,绕开归档服务缺陷。
# 用法:
#   scripts/export-ipa.sh                # 默认 development(装测试机)
#   scripts/export-ipa.sh app-store      # 上传 App Store
# 产物:/tmp/MiniClaw-<时间戳>.xcarchive + /tmp/MiniClaw-ipa-<时间戳>/MiniClaw.ipa
set -euo pipefail
cd "$(dirname "$0")/.."

METHOD="${1:-development}"
TEAM="${DEVELOPMENT_TEAM:-LZ84D5PQ38}"
# 派生目录与纪律定案一致：固定复用 ~/.miniclaw-build（增量构建，产物不进工程树）。
# 可用 MINICLAW_DERIVED_DATA 覆盖。
DERIVED_DATA="${MINICLAW_DERIVED_DATA:-$HOME/.miniclaw-build}"
STAMP=$(date +%Y%m%d-%H%M)
ARCHIVE="/tmp/MiniClaw-$STAMP.xcarchive"
OUT="/tmp/MiniClaw-ipa-$STAMP"

echo "==> [1/4] xcodebuild archive (method=$METHOD, team=$TEAM)"
xcodebuild archive \
  -project MiniClaw.xcodeproj -scheme MiniClaw \
  -destination 'generic/platform=iOS' \
  -archivePath "$ARCHIVE" \
  -derivedDataPath "$DERIVED_DATA" \
  OTHER_SWIFT_FLAGS="-Xfrontend -disable-sandbox" \
  -allowProvisioningUpdates 2>&1 | tail -3

echo "==> [2/4] 补全 ApplicationProperties(Xcode 26.6 归档服务回归:不写此键 Organizer 不识别)"
python3 - "$ARCHIVE" "$TEAM" <<'PYEOF'
import plistlib, subprocess, sys, os
arch, team = sys.argv[1], sys.argv[2]
app = os.path.join(arch, 'Products/Applications/MiniClaw.app')
app_plist_path = os.path.join(app, 'Info.plist')
with open(app_plist_path, 'rb') as f:
    app_plist = plistlib.load(f)
ident = subprocess.run(['codesign', '-d', '-vv', app], capture_output=True, text=True).stderr
sign = ''
for line in ident.splitlines():
    if line.startswith('Authority=') and ('Apple Development' in line or 'Apple Distribution' in line):
        sign = line.split('=', 1)[1]
        break
info = os.path.join(arch, 'Info.plist')
with open(info, 'rb') as f:
    d = plistlib.load(f)
d['ApplicationProperties'] = {
    'ApplicationPath': 'Applications/MiniClaw.app',
    'Architectures': ['arm64'],
    'CFBundleIdentifier': app_plist.get('CFBundleIdentifier', ''),
    'CFBundleShortVersionString': app_plist.get('CFBundleShortVersionString', ''),
    'CFBundleVersion': app_plist.get('CFBundleVersion', ''),
    'SigningIdentity': sign,
    'Team': team,
}
with open(info, 'wb') as f:
    plistlib.dump(d, f, sort_keys=False)
print('ApplicationProperties 已补全:', app_plist.get('CFBundleShortVersionString'), f"({app_plist.get('CFBundleVersion')})")
PYEOF

echo "==> [3/4] 生成 exportOptions.plist"
cat > /tmp/export-options-$STAMP.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>$METHOD</string>
  <key>teamID</key><string>$TEAM</string>
  <key>signingStyle</key><string>automatic</string>
</dict></plist>
PLIST

echo "==> [4/4] xcodebuild -exportArchive"
# -allowProvisioningUpdates:自动从开发者账号刷新 App Store profile
# (刚创建的 Distribution 证书需让 Xcode 重新生成包含它的 profile)。
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportOptionsPlist /tmp/export-options-$STAMP.plist \
  -exportPath "$OUT" \
  -allowProvisioningUpdates 2>&1 | tail -3

echo "==> 完成"
echo "  Archive: $ARCHIVE"
echo "  IPA:     $OUT/MiniClaw.ipa"
echo "  (上传 App Store:把 ipa 拖进 Transporter,或 xcrun altool --upload-app -f \"$OUT/MiniClaw.ipa\" ...)"
