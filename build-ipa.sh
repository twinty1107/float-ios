#!/usr/bin/env bash
#
# 在 macOS 上把 float 的 iOS 封装工程编译成可安装的 .ipa
#
#   方式 A（推荐，自动签名，需登录过的 Apple ID）：
#       ./build-ipa.sh --team ABCDE12345
#   方式 B（手动签名，用导出的 .p12 + .mobileprovision）：
#       ./build-ipa.sh --p12 ~/certs/dev.p12 --p12-pass 123456 --profile ~/certs/app.mobileprovision
#
# 产物：dist/float-<版本>.ipa 和 dist/float-unsigned.ipa
#
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$PROJECT_DIR"

SCHEME="FloatApp"
PROJECT="FloatApp.xcodeproj"
CONFIG="Release"
DERIVED="$PROJECT_DIR/build"
DIST="$PROJECT_DIR/dist"
BUNDLE_ID="net.meou123.float"

TEAM=""
P12=""
P12_PASS=""
PROFILE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --team)     TEAM="$2"; shift 2 ;;
    --p12)      P12="$2"; shift 2 ;;
    --p12-pass) P12_PASS="$2"; shift 2 ;;
    --profile)  PROFILE="$2"; shift 2 ;;
    --bundle-id) BUNDLE_ID="$2"; shift 2 ;;
    -h|--help)  sed -n '2,12p' "$0"; exit 0 ;;
    *) echo "未知参数: $1" >&2; exit 2 ;;
  esac
done

command -v xcodebuild >/dev/null || { echo "错误：需要 macOS + Xcode（xcodebuild 未找到）。"; exit 1; }
mkdir -p "$DIST"

# ---------------------------------------------------------------- 方式 A：自动签名
build_auto() {
  local args=(-project "$PROJECT" -scheme "$SCHEME" -configuration "$CONFIG"
              -destination 'generic/platform=iOS' -derivedDataPath "$DERIVED"
              -archivePath "$DERIVED/FloatApp.xcarchive"
              CODE_SIGN_STYLE=Automatic
              PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_ID")
  [[ -n "$TEAM" ]] && args+=(DEVELOPMENT_TEAM="$TEAM")
  echo "==> xcodebuild archive (automatic signing)"
  xcodebuild "${args[@]}" archive

  local team="${TEAM:-$(/usr/libexec/PlistBuddy -c 'Print :ApplicationProperties:TeamIdentifier:0' \
                        "$DERIVED/FloatApp.xcarchive/Info.plist" 2>/dev/null || true)}"
  [[ -z "$team" ]] && { echo "错误：无法确定 Team ID，请显式传 --team。"; exit 1; }

  local export="$DERIVED/ExportOptions.plist"
  cat > "$export" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>development</string>
  <key>signingStyle</key><string>automatic</string>
  <key>teamID</key><string>$team</string>
  <key>stripSwiftSymbols</key><true/>
  <key>compileBitcode</key><false/>
</dict></plist>
PLIST

  echo "==> xcodebuild -exportArchive"
  xcodebuild -exportArchive -archivePath "$DERIVED/FloatApp.xcarchive" \
             -exportPath "$DIST/export" -exportOptionsPlist "$export"

  local app; app="$(/usr/bin/find "$DIST/export" -maxdepth 1 -name '*.ipa' | head -n1)"
  [[ -n "$app" ]] || { echo "错误：导出未产生 ipa。"; exit 1; }
  mv "$app" "$DIST/float-$TEAM.ipa"
  cp "$DIST/float-$TEAM.ipa" "$DIST/float-signed.ipa"
}

# ---------------------------------------------------------------- 方式 B：手动签名
build_manual() {
  local keychain="$DERIVED/sign.keychain-db" kc_pass="dsh-float"
  rm -rf "$DERIVED/FloatApp.xcarchive" "$DERIVED/Build"
  security delete-keychain "$keychain" 2>/dev/null || true
  security create-keychain -p "$kc_pass" "$keychain"
  security set-keychain-settings -lut 3600 "$keychain"
  security unlock-keychain -p "$kc_pass" "$keychain"
  security import "$P12" -k "$keychain" -P "$P12_PASS" -T /usr/bin/codesign -T /usr/bin/security
  security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$kc_pass" "$keychain" >/dev/null

  echo "==> xcodebuild build (manual signing, unsigned product)"
  xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration "$CONFIG" \
             -destination 'generic/platform=iOS' -derivedDataPath "$DERIVED" \
             -archivePath "$DERIVED/FloatApp.xcarchive" \
             CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
             PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_ID" build

  local app="$DERIVED/Build/Products/$CONFIG-iphoneos/$SCHEME.app"
  [[ -d "$app" ]] || { echo "错误：未找到构建产物 $app"; exit 1; }

  # 从 mobileprovision 解析 entitlements，注入后才具备推送/钥匙串等能力
  local prof_plist="$DERIVED/profile.plist" ent="$DERIVED/entitlements.plist"
  security cms -D -i "$PROFILE" > "$prof_plist"
  /usr/libexec/PlistBuddy -x -c 'Print :Entitlements' "$prof_plist" > "$ent"
  /usr/libexec/PlistBuddy -c "Set :application-identifier $TEAM.$BUNDLE_ID" "$ent" 2>/dev/null || true

  cp "$PROFILE" "$app/embedded.mobileprovision"
  local identity; identity="$(security find-identity -v -p codesigning "$keychain" | awk 'NR==1{print $2}')"
  [[ -n "$identity" ]] || { echo "错误：keychain 中没有可用签名证书。"; exit 1; }

  echo "==> codesign (identity ${identity:0:12}…)"
  /usr/bin/find "$app" -name '*.dylib' -o -name '*.so' -o -name '*.framework' -print0 2>/dev/null |
    while IFS= read -r -d '' item; do codesign --force --sign "$identity" --timestamp=none "$item"; done
  codesign --force --sign "$identity" --entitlements "$ent" --timestamp=none "$app"
  codesign --verify --deep --strict "$app" && echo "签名校验通过"

  rm -rf "$DERIVED/ipa" && mkdir -p "$DERIVED/ipa/Payload"
  cp -R "$app" "$DERIVED/ipa/Payload/"
  # ditto --norsrc 避免写入 __MACOSX/AppleDouble 元数据
  /usr/bin/ditto -c -k --norsrc --keepParent "$DERIVED/ipa/Payload" "$DIST/float-signed.ipa"
  echo "已签名 IPA：$DIST/float-signed.ipa"
}

if [[ -n "$P12" && -n "$PROFILE" ]]; then
  build_manual
elif [[ -n "$P12" || -n "$PROFILE" ]]; then
  echo "错误：--p12 与 --profile 必须同时提供。" >&2; exit 2
else
  build_auto
fi

# ---------------------------------------------------------------- 同时产出一个未签名 IPA
if [[ -d "$DERIVED/FloatApp.xcarchive" || -d "$DERIVED/Build" ]]; then
  app="$(/usr/bin/find "$DERIVED" -name "$SCHEME.app" -maxdepth 6 -type d | head -n1 || true)"
  if [[ -n "$app" ]]; then
    rm -rf "$DERIVED/ipa-unsigned" && mkdir -p "$DERIVED/ipa-unsigned/Payload"
    cp -R "$app" "$DERIVED/ipa-unsigned/Payload/"
    ( cd "$DERIVED/ipa-unsigned" && /usr/bin/zip -qry "$DIST/float-unsigned.ipa" Payload )
    echo "未签名 IPA：$DIST/float-unsigned.ipa"
  fi
fi

echo
echo "完成。安装方式："
echo "  • 有 Mac：Xcode > Window > Devices and Simulators 拖入 IPA；或 \`xcrun devicectl device install app\`"
echo "  • 无 Mac：用 Sideloadly / AltStore / ESign 重新签名后安装（免费 Apple ID 签名为 7 天有效期）"
