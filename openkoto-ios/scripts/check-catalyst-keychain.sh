#!/bin/bash
# 检查 Mac Catalyst 产物是否具备访问 data-protection keychain 的资格。
# 缺 application-identifier / keychain-access-groups 时，SecItemAdd 返回
# errSecMissingEntitlement(-34018) 并静默失败 —— API Key 看着存了，其实没存。
APP=$(ls -td ~/Library/Developer/Xcode/DerivedData/OpenKoto-*/Build/Products/Debug-maccatalyst/OpenKoto.app 2>/dev/null | head -1)
[ -z "$APP" ] && { echo "找不到 Catalyst 产物，先在 Xcode 里 Run 一次"; exit 1; }
echo "产物：$APP"
echo "签名时间：$(codesign -dvv "$APP" 2>&1 | grep 'Signed Time' | cut -d= -f2-)"
[ -f "$APP/Contents/embedded.provisionprofile" ] && echo "描述文件：有" || echo "描述文件：无"
ENT=$(codesign -d --entitlements - --xml "$APP" 2>/dev/null | plutil -convert xml1 -o - - 2>/dev/null)
if grep -qE "application-identifier|keychain-access-groups" <<<"$ENT"; then
  echo "✅ Keychain 资格：有"
  grep -A1 -E "application-identifier|keychain-access-groups" <<<"$ENT" | grep string
else
  echo "❌ Keychain 资格：无 —— API Key 会静默存不进去"
fi

# iCloud 容器缺失同样是静默失败：同步一声不吭地什么都不做。
if grep -q "icloud-container-identifiers" <<<"$ENT"; then
  echo "✅ CloudKit 容器：有"
  grep -A2 "icloud-container-identifiers" <<<"$ENT" | grep string
else
  echo "❌ CloudKit 容器：无 —— 跨设备同步会静默不工作"
fi
