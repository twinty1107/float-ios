#!/bin/bash
# 校验 float iOS 工程结构，并检查未签名 IPA 的内部布局
set -u
cd "$(dirname "$0")"

fail=0
check() { # check <描述> <路径>
  if [ -e "$2" ]; then printf '  [ok]   %s\n' "$1"; else printf '  [MISS] %s -> %s\n' "$1" "$2"; fail=1; fi
}

echo "== 工程结构 =="
check "Swift 入口"        FloatApp/AppDelegate.swift
check "WebView 控制器"    FloatApp/WebAppViewController.swift
check "Info.plist"        FloatApp/Info.plist
check "图标 1024"         FloatApp/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png
check "AppIcon 描述"      FloatApp/Assets.xcassets/AppIcon.appiconset/Contents.json
check "启动背景色"        FloatApp/Assets.xcassets/LaunchBackground.colorset/Contents.json
check "Xcode 工程"        FloatApp.xcodeproj/project.pbxproj
check "workspace"         FloatApp.xcodeproj/project.xcworkspace/contents.xcworkspacedata

echo "== Info.plist 关键键 =="
for key in CFBundleIdentifier CFBundleDisplayName CFBundleShortVersionString \
           CFBundleExecutable UILaunchScreen NSPhotoLibraryUsageDescription \
           NSCameraUsageDescription NSMicrophoneUsageDescription \
           NSLocationWhenInUseUsageDescription UISupportedInterfaceOrientations; do
  if /usr/bin/plutil -extract "$key" raw -o - FloatApp/Info.plist >/dev/null 2>&1; then
    printf '  [ok]   %s = %s\n' "$key" "$(/usr/bin/plutil -extract "$key" raw -o - FloatApp/Info.plist 2>/dev/null | head -n1)"
  else
    printf '  [MISS] %s\n' "$key"; fail=1
  fi
done

echo "== 未签名 IPA =="
if [ -f dist/float-unsigned.ipa ]; then
  /usr/bin/unzip -l dist/float-unsigned.ipa | sed 's/^/  /'
  echo "  含 embedded.mobileprovision: $(/usr/bin/unzip -l dist/float-unsigned.ipa | grep -c embedded.mobileprovision)"
  echo "  含 _CodeSignature: $(/usr/bin/unzip -l dist/float-unsigned.ipa | grep -c _CodeSignature)"
else
  echo "  [MISS] dist/float-unsigned.ipa"; fail=1
fi

echo
[ "$fail" -eq 0 ] && echo "结论：结构完整。" || echo "结论：存在缺失项（见上）。"
exit "$fail"
