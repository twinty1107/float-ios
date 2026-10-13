# 没有 Mac 怎么拿到能自签的 IPA

## 为什么不能直接用 `dist/float-unsigned.ipa`

那个 IPA 是为了让你检视包结构而生成的，里面的可执行文件是 Windows 上合成的 **4 KB 占位 Mach-O**
（只有 arm64 文件头，没有 `__TEXT` 段、没有 `LC_LOAD_DYLIB`、没有 `LC_MAIN` 入口点）。

自签工具（Sideloadly / ESign / AltStore / TrollStore）只做**替换签名**：
把证书和描述文件套到 IPA 里**已经编译好**的可执行文件上。占位符虽然也能被 `codesign` 签上，
但它不是可运行代码，安装后由 `dyld` 加载时会直接失败。

**签名 ≠ 编译。** 编译 iOS 二进制必须用 Apple 的 Xcode + iPhoneOS SDK，而 Xcode 只在 macOS 上运行。

## 解决方案：用 GitHub Actions 的免费 macOS runner 编译

GitHub 对公开仓库免费提供 macOS runner（私有仓库每月 2000 分钟）。整个流程你都在 Windows 上操作。

### 步骤

1. **建仓库并上传工程**

   把 `float-ios/` 里的这些内容推到 GitHub（`.github/` 目录也要推上去）：

   ```
   FloatApp/                 工程源码
   FloatApp.xcodeproj/       Xcode 工程
   .github/workflows/build-ipa.yml
   ```

   > 注意：`.github` 是隐藏目录，用 GitHub 网页拖拽上传时确认它没被忽略。

2. **运行构建**

   仓库页面 → **Actions** → 左侧选 **Build unsigned iOS IPA** → **Run workflow**。
   默认 Bundle ID 是 `net.meou123.float`；如果你自签时描述文件要求别的 ID，在这里改。

3. **下载产物**

   跑完约 2–4 分钟。进入那次运行，页面底部 **Artifacts** 里下载
   `float-0.1.0-1-unsigned`，解压得到 `float-0.1.0-1-unsigned.ipa`。

   这个 IPA 里是**真正编译出来的 arm64 可执行文件**（工作流会在日志里打印 `lipo -archs` 和文件大小做校验），
   这就是你要拿去自签的东西。

4. **用全能签自签安装**

   **全能签**读的就是"已编译、未签名"的 IPA（它内部用 `ldid` 重签并自动匹配描述文件），
   本工作流的产物正好对应，流程：

   1. 把下载到的 `float-0.1.0-1-unsigned.ipa` 传到 iPhone（AirDrop / 文件 App / 电脑助手都行）
   2. 用全能签打开这个 IPA，或在全能签里「导入」→ 选该文件
   3. 选你的签名证书（免费 Apple ID 或企业证书）
   4. 点签名 → 安装

   **如果报 Bundle ID 冲突或签名失败**：回到 Actions 重新 Run workflow，
   把 `bundle_id` 输入框改成 `com.你的名字.float` 再构建一次。
   （全能签里通常也能直接改 Bundle ID，两处任选一处即可。）

   > 免费 Apple ID 签出来的 App **7 天后过期**，需要重新签一次；
   > 用全能签里的企业/共享证书则取决于证书本身的有效期。

   其他工具对照：

   | 工具 | 说明 |
   | --- | --- |
   | **全能签**（iOS 端） | 手机内导入 IPA → 选证书 → 重签安装，无需电脑 |
   | **ESign / Scarlet**（iOS 端） | 同上，界面不同 |
   | **Sideloadly**（Windows 桌面） | 连数据线拖入 IPA，填 Apple ID 一键签名 |
   | **AltStore** | 需先装 AltServer（Windows 可用），再在设备上导入 IPA |
   | **TrollStore** | 仅特定 iOS 版本，永久签名不过期 |

### 关于"云端排队"

GitHub Actions 的 macOS runner 与"iOS 云签平台"是两回事：

- **公开仓库**：macOS runner **完全免费、不消耗额度**，实测通常几十秒内就开始跑，基本不排队
- **私有仓库**：免费额度 2000 分钟/月，macOS runner 按 **10 倍**计费（即实际约 200 分钟），
  本项目单次构建 1–3 分钟，够用约 60–100 次

工作流里已经做了提速：`SUPPORTED_PLATFORMS=iphoneos` + `ARCHS=arm64`，
只编真机 arm64、不编模拟器切片，是这个工程能压到最快的配置。
工程本身只有 2 个 Swift 文件、无第三方依赖，所以瓶颈基本只剩 runner 启动和队列。

如果你仍然遇到排队，备选：

| 平台 | 说明 |
| --- | --- |
| **Codemagic** | 免费层每月 500 分钟 macOS M2，注册即可用，通常不排队 |
| **Bitrise** | 免费层有 macOS 构建机时额度 |
| **借用一台 Mac** | 只有这一条能完全不等：`xcodebuild` 本地编，1 分钟内出结果 |


### 需要签名证书的话

工作流里已经预留了带证书签名的分支：把 `signed` 设为 `true`，并配置这几个 Secrets：

| Secret | 内容 |
| --- | --- |
| `IOS_CERT_P12_BASE64` | 你的 `.p12` 证书，base64 后的文本 |
| `IOS_CERT_PASSWORD` | `.p12` 的密码 |
| `IOS_PROVISION_BASE64` | `.mobileprovision` 描述文件，base64 后的文本 |
| `IOS_TEAM_ID` | 10 位 Team ID |

Windows 上生成 base64 文本：

```powershell
[Convert]::ToBase64String([IO.File]::ReadAllBytes("C:\path\cert.p12")) | Set-Clipboard
```

**重要前提**：`.mobileprovision` 必须包含你构建时用的那个 Bundle ID，否则签名会失败。
自签工具会自动处理这一步，所以一般情况下用**未签名产物 + 自签工具**这条路径更省事。

### 关于免费 Apple ID

免费账号能签，但**签名 7 天后过期**，需要重新签一次；而且最多同时 3 个自签 App。
要长期使用需要 Apple Developer Program（$99/年）。

## 一条更短的路（如果你有 iPhone 或 iPad 上的自签 App）

iOS 16.0–16.6.1 / 17.0 等特定版本可以装 **TrollStore**，它用系统签名漏洞做**永久签名**，
装完不再需要电脑和证书。前提是版本匹配，且你已经有办法装上 TrollStore 本身。
