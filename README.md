# float — iOS 打包（IPA）

把 <https://meou123.netlify.app/> 这个 Next.js PWA 封装成原生 iOS App，并产出 `.ipa`。

- 站点名称：**float**（`manifest.webmanifest` 已声明 `display: standalone` / 竖屏 / 黑色主题）
- App 显示名：`float`
- Bundle ID：`net.meou123.float`
- 最低系统：iOS 15.0（iPhone + iPad）
- 语言：Swift + WKWebView，无第三方依赖

---

## 1. 先说清楚一个硬约束

**本仓库的原始工作环境是 Windows，没有 macOS / Xcode。**
iOS 可执行文件是 ARM64 Mach-O，必须用 Apple 的 Xcode / clang + iPhoneOS SDK 编译并做代码签名；
在 Windows 上无法生成一个"能装的" iOS App 二进制。因此这里交付两部分：

| 交付物 | 说明 |
| --- | --- |
| `FloatApp/` + `FloatApp.xcodeproj/` | **完整可编译的 Xcode 工程**，在 macOS 上一条命令出 IPA |
| `dist/float-unsigned.ipa` | 结构完整的**未签名** IPA 骨架，用于检视布局；里面的 `FloatApp` 是占位 Mach-O，**不能安装运行** |

要得到能装到手机上的 IPA，见下面第 3 节的三条路径。

---

## 2. 工程结构

```
float-ios/
├── FloatApp/
│   ├── AppDelegate.swift            程序入口，创建 UIWindow
│   ├── WebAppViewController.swift   WKWebView 外壳（核心逻辑）
│   ├── Info.plist                   权限声明、竖屏锁、启动屏
│   └── Assets.xcassets/
│       ├── AppIcon.appiconset/      从站点 icon-512.png 转出的 1024 图标
│       └── LaunchBackground.colorset 黑色启动背景（与站点主题一致）
├── FloatApp.xcodeproj/              Xcode 工程（objectVersion 56 / Xcode 14+）
├── .github/workflows/build-ipa.yml  在 GitHub 免费 macOS runner 上编译（无 Mac 可用）
├── build-ipa.sh                     macOS 构建 + 签名 + 导出 IPA
├── CI-SIGNING.md                    无 Mac 时的完整流程说明
├── verify.sh                        工程与 IPA 结构校验（macOS）
└── dist/float-unsigned.ipa          未签名 IPA 骨架（占位二进制，不能安装）
```

### 外壳实现了什么

- WKWebView 加载 `https://meou123.netlify.app/`，全屏、黑色背景、`viewport-fit=cover` 适配刘海与底部横条
- 竖屏锁定（与站点 manifest 的 `orientation: portrait` 一致）
- 启动页淡出、顶部加载进度条、下拉刷新
- 离线/加载失败时显示中文错误页 + "重新加载"按钮
- 站内链接留在 App 内；站外链接用 Safari 打开（避免变成"浏览器牢笼"）
- `window.open` / `target=_blank` 在站内时同窗口打开
- `tel:` `mailto:` `weixin:` `alipay:` 等自定义 scheme 交给系统
- 打开 JS 弹窗（alert / confirm / prompt）的原生代理实现
- 允许站内页面使用**麦克风**（站点用它做语音录制）、摄像头、相册上传
- WKWebView 进程崩溃后自动重载

### 权限来自实测

扫描站点 18 个 JS chunk（约 7.4 MB）后确认：

| 能力 | 实测情况 | Info.plist |
| --- | --- | --- |
| 麦克风 `getUserMedia({audio:true})` + `MediaRecorder` | **实际使用**（语音录制 / 语音转文字） | `NSMicrophoneUsageDescription` |
| 文件上传 `<input type=file>` | 实际使用 | 相册权限 |
| `Notification.requestPermission` + `serviceWorker` | 实际使用（Web 推送） | 无原生键（WKWebView 不支持 Web Push） |
| 摄像头 / 定位 / 语音识别 | 未在 bundle 中实测到调用 | 已保守声明，避免将来调用崩溃 |

---

## 3. 怎么拿到可安装的 IPA

### 路径 A：有 Mac（最简单，最正规）

```bash
cd float-ios
./build-ipa.sh --team <你的10位TeamID>     # Xcode 里登录过 Apple ID 即可自动签名
# 需要手动签名的场景：
./build-ipa.sh --p12 dev.p12 --p12-pass 123456 --profile app.mobileprovision --team <TeamID>
```

产物：`dist/float-<TeamID>.ipa`（已签名）/ `dist/float-signed.ipa`（手动签名）/ `dist/float-unsigned.ipa`

装到 iPhone：

- Xcode → Window → Devices and Simulators → 把 `.ipa` 拖进去；或
- `xcrun devicectl device install app --device <UDID> FloatApp.app`；或
- 免费 Apple ID 也可以，但签名 **7 天过期**，需要重新装。

### 路径 B：没有 Mac，用 Windows 重签名

1. 先在 macOS 或 CI 上跑一次 `./build-ipa.sh`（或下面路径 C），拿到**已编译**的 IPA；
   本仓库 `dist/float-unsigned.ipa` 只是骨架，**不能**用这条路径。
2. Windows 上装 [Sideloadly](https://sideloadly.io/) 或 AltStore，用你的 Apple ID 重签名后安装。
   免费账号同样 7 天有效期。

> 说明：Sideloadly / AltStore / ESign 这类工具做的是**替换签名**，
> 前提是 IPA 里已经有真正编译出来的 ARM64 可执行文件。

### 路径 C：没有 Mac，用 GitHub Actions 的免费 macOS runner（推荐给无 Mac 的情况）

推到 GitHub → Actions → **Build unsigned iOS IPA** → Run workflow，
2–4 分钟后在 Artifacts 下载**真正编译好**的未签名 IPA，再用 ESign / Sideloadly 自签。

详细步骤、Bundle ID 冲突处理、证书 Secrets 配置见 **[CI-SIGNING.md](CI-SIGNING.md)**。

> ⚠️ `dist/float-unsigned.ipa` **不能**用来自签：它内部是 4 KB 占位 Mach-O，
> 自签工具只替换签名、不负责编译，装上去会闪退。自签请务必用路径 B / C 产出的 IPA。

---

## 4. 改配置的常见位置

| 想改什么 | 改哪里 |
| --- | --- |
| 加载别的网址 | `WebAppViewController.swift` 里的 `Config.startURL` |
| 哪些域名留在 App 内 | `Config.inAppHosts` |
| App 名称 | `Info.plist` → `CFBundleDisplayName`（当前 `float`） |
| Bundle ID | `project.pbxproj` → `PRODUCT_BUNDLE_IDENTIFIER`（当前 `net.meou123.float`） |
| 版本号 | `Info.plist` 的 `CFBundleShortVersionString` + `project.pbxproj` 的 `MARKETING_VERSION` |
| 图标 | 替换 `AppIcon.appiconset/AppIcon-1024.png`（1024×1024 PNG，不要透明通道） |
| 允许横屏 | `Info.plist` → `UISupportedInterfaceOrientations` 加 `UIInterfaceOrientationLandscapeLeft/Right` |

## 5. 校验

在 macOS 上：

```bash
./verify.sh
```

会检查工程文件完整性、`Info.plist` 关键键、以及 IPA 内是否含 `embedded.mobileprovision`
和 `_CodeSignature`（未签名 IPA 这两项应为 0，签名后应为 1）。
