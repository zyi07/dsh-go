# DSH Go 双端开发与构建指南

本项目为 **DeepSeek Harness (DSH)** 的移动端载体，涵盖 **Android** 与 **HarmonyOS (鸿蒙 Next / API 26+)** 双端原生应用开发，支持手机端本地运行打过补丁的 DSH 引擎，也支持通过多种协议（直连、中继、WebRTC、LAN、SSH）连接远程服务器。

本文档详细梳理双端开发环境搭建、依赖矩阵、技术栈规范、核心构建管线及真机调试排错方法。

---

## 一、系统架构与双端实现差异

```
               ┌──────────────────────────────────────────────┐
               │        Flutter 统一前端 (UI & 状态管理)        │
               │   Riverpod 2.x · go_router · l10n · Material3 │
               └──────────────────────┬───────────────────────┘
                                      │
            ┌─────────────────────────┴─────────────────────────┐
            ▼                                                   ▼
┌───────────────────────┐                           ┌───────────────────────┐
│     Android 运行时     │                           │    HarmonyOS 运行时    │
├───────────────────────┤                           ├───────────────────────┤
│ • PRoot Linux 隔离沙箱 │                           │ • Stage 模型 ArkTS 宿主│
│ • arm64-v8a Ubuntu 根 │                           │ • AArch64 libnode.so  │
│ • 标准 Node 24 二进制 │                           │ • libdsh_host 原生扩展 │
│ • 113 项 DSH 公共补丁  │                           │ • 144 项专用/覆盖补丁   │
│ • HTTP Bridge 桥接通讯 │                           │ • ZIP_STORED 单归档载荷│
└───────────────────────┘                           └───────────────────────┘
```

### 1.1 前端核心技术栈
- **框架语言**：Flutter 3.47.x / Dart 3.13.x
- **状态管理**：`flutter_riverpod` (Notifier / AsyncNotifier 响应式驱动)
- **路由导航**：`go_router` (声明式深层链接)
- **网络与通信**：`dsh_client` (纯 Dart HTTP/SSE 客户端，支持会话持久流与删除)；`dsh_remote` (WebRTC、SOCKS5、直连 HTTPS+Token)
- **国际化**：ARB 模版驱动，执行 `python app/tool/l10n_merge.py` 自动化生成

### 1.2 Android 端架构
- **宿主环境**：通过 PRoot 机制在 Android 沙箱内模拟 Linux rootfs，不需要手机 root。
- **运行载荷**：Debian/Ubuntu 精简根文件系统，内嵌 Node.js 24 运行 `dsh web`。
- **进程通讯**：App 启动 PRoot 子进程，通过本地 Loopback HTTP 桥（`/dsh-go/v1/*`）通信。

### 1.3 HarmonyOS 端架构
- **宿主环境**：鸿蒙不允许通用 PRoot 或外部动态加载未签名二进制，引擎直接作为应用内原生动态库运行。
- **原生层 (Native C/C++)**：
  - `libnode.so`：专为 `aarch64-linux-ohos` 目标编译的 Node 24.22.1 共享库，静态集成 libc++。
  - `libdsh_host.so`：通过 N-API 实现 ArkTS 与 Node 运行时实例绑定的宿主扩展。
  - `libdsh_flock.so` & `libdsh_require_builtin.so`：文件锁与内置模块加载辅助库。
- **运行时载荷 (Rawfile Asset)**：
  - 由 12,375 个文件经 `compose-runtime.py` 压缩为 `dsh-runtime/runtime.zip`，存放在 HAP 的 `resources/rawfile/` 中。
  - **重要约束**：HAP 内该条目必须保持 **`ZIP_STORED` (无压缩)** 状态，供系统 `resourceManager.getRawFd()` 读取。

---

## 二、双端开发依赖与工具链矩阵

### 2.1 依赖版本对照表

| 组件 / 依赖 | Android 端要求 | HarmonyOS 端要求 | 说明 |
| :--- | :--- | :--- | :--- |
| **Flutter SDK** | 3.47.7 (Dart 3.13.5) | oh-flutter 3.47.9-ohos-1.0.0 (Dart 3.13.3) | 鸿蒙必须使用华为适配分支的 Flutter |
| **Java 开发环境** | JDK 17 / JDK 21 | DevEco Studio 内置 JBR (JDK 17) | 统一配置 `JAVA_HOME` |
| **编译主机 OS** | Windows / Linux / macOS | Windows (打包) + Linux/WSL (编译原生库) | 鸿蒙 libnode 交叉编译目前依赖 Linux |
| **系统原生 SDK** | Android SDK API 34+ (Build-tools 36.0.0) | DevEco Studio 26+ (SDK 6.1.0.31 / API 26) | 配置 `DEVECO_SDK_HOME` / `HOS_SDK_HOME` |
| **构建管理工具** | Gradle 8.x | hvigor 6.26.x + ohpm | DevEco Studio 内置提供 |
| **C/C++ 编译器** | Android NDK r26+ | LLVM / Clang 23.1.1 + llvm-project 23 源码 | 编译 Node 24 必须 Clang 23+（支持 crc32b） |
| **Node.js** | Node 24.x / npm 11.x | Node 24.22.1 源码 + npm 11.9.0 | 用于 DSH 前缀组装与补丁校验 |
| **调试桥接工具** | `adb` (Android Platform Tools) | `hdc` (OpenHarmony SDK Toolchains) | 均支持 USB 或 Wi-Fi 无线调试 |

### 2.2 环境变量推荐配置 (Windows 示例)

```bash
# Android
export ANDROID_HOME="D:/Data/dev-toolchain/android-sdk"
export PATH="$ANDROID_HOME/platform-tools:$PATH"

# HarmonyOS
export DEVECO_SDK_HOME="C:/Program Files/Huawei/DevEco Studio/sdk"
export HOS_SDK_HOME="$DEVECO_SDK_HOME"
export JAVA_HOME="C:/Program Files/Huawei/DevEco Studio/jbr"
export NODE_HOME="C:/Program Files/Huawei/DevEco Studio/tools/node"
export PATH="$JAVA_HOME/bin:$NODE_HOME:$PATH:/c/Program Files/Huawei/DevEco Studio/tools/hvigor/bin:/c/Program Files/Huawei/DevEco Studio/tools/ohpm/bin"
export FLUTTER_OHOS="D:/code/flutter-ohos-3479/bin/flutter"

# Python (必须开启 UTF-8 模式)
export PYTHONUTF8=1
export PYTHONIOENCODING=utf-8
```

---

## 三、代码规范与补丁系统机制

### 3.1 DSH 引擎补丁集 (`runtime/patches/pins.json`)
DSH 采用基于哈希锁定的补丁系统（schema 2），确保上游 Node 模块应用补丁后文件内容绝对确定：
- `targetSets.android`：包含 113 项公共补丁，应用于 Android rootfs 中的 DSH 模块。
- `targetSets.ohos`：包含 144 项补丁（113 项公共补丁 + 31 项鸿蒙专用适配补丁）。
- 校验命令：
  ```bash
  python runtime/lib/rtbuild.py patch-dsh --prefix <npm-prefix> --dsh-version 0.2.2-rc.1 --target android
  python runtime/lib/rtbuild.py patch-dsh --prefix <npm-prefix> --dsh-version 0.2.2-rc.1 --target ohos
  ```

### 3.2 仓库开发规范 (遵守 AGENTS.md)
1. **外部 PR 禁令**：本仓库暂不接受外部 PR；若要贡献请提交 Issue。
2. **生成文件保护**：禁止手改 `app/lib/l10n/gen/`、`.dart_tool/`、`site/build/`。
3. **文档与翻译同步**：界面文案修改 `app/lib/l10n/parts/*.arb` 后必须运行 `python3 app/tool/l10n_merge.py`；用户手册修改 `docs/guide/` 后必须运行 `python3 app/tool/guide_sync.py`。
4. **Git 暂存**：只暂存明确修改的文件，严禁 `git add .` 或 `git add -A`。

---

## 四、Android 端编译与打包

### 4.1 开发调试
```bash
cd app
flutter pub get
flutter analyze
flutter test
# 启动真机调试
flutter run -d <device-id>
```

### 4.2 正式打包
执行构建脚本生成正式 APK：
```bash
bash tooling/build-apk.sh --build-name 1.0.14
```
产物输出在 `dist/dsh-go-1.0.14-android-arm64.apk`。

---

## 五、HarmonyOS 端编译、原生库构建与完整打包

鸿蒙端编译分为两层：**前端 HAP 编译** 与 **原生运行时跨端构建**。

### 5.1 步骤一：在 Linux/WSL 中编译原生库与运行时
由于鸿蒙的 Node 24 动态库需调用特化 C++ 特性，需在 Linux (如 Ubuntu WSL) 中执行：
```bash
# 1. 构建静态 libc++ 运行时
python3 runtime/ohos/node/build-runtimes.py \
  --sdk-native /opt/ohos-sdk/native \
  --clang /opt/llvm-23/bin/clang \
  --source-archive /opt/llvm-project-23.1.1.src.tar.xz \
  --work /tmp/rt-work --output /tmp/rt-out --jobs 6

# 2. 交叉编译 libnode.so
python3 runtime/ohos/node/build-node.py \
  --sdk-native /opt/ohos-sdk/native \
  --clang /opt/llvm-23/bin/clang \
  --cxx-runtime /tmp/rt-out \
  --source-archive /opt/node-v24.22.1.tar.xz \
  --host-node /usr/bin/node \
  --work /tmp/node-work --output /tmp/node-out --jobs 6

# 3. 编译配套原生库 (libdsh_host / libdsh_flock / libdsh_require_builtin)
python3 runtime/ohos/native/build-hap-libs.py \
  --sdk-native /opt/ohos-sdk/native \
  --clang /opt/llvm-23/bin/clang \
  --cxx-runtime /tmp/rt-out \
  --libnode-output /tmp/node-out \
  --node-source /tmp/node-src \
  --flock-package /path/to/node-addon-system \
  --loader-source /path/to/loader-src \
  --node-addon-api /path/to/node-addon-api \
  --work /tmp/hap-work --output /opt/build/hap-libs

# 4. 组装 12,375 文件的压缩运行时归档
python3 runtime/ohos/package/prepare-inputs.py --target ohos ...
python3 runtime/ohos/package/compose-runtime.py --target ohos ...
# 输出产物：dsh-runtime-rawfile.zip (内部包含纯净 runtime.zip)
```

### 5.2 步骤二：构建 HAP 并组装全量包
在 Windows 环境下使用 `oh-flutter` 编译：
```bash
# 编译未签名 debug HAP（带 --no-codesign 避免 AGC 弹窗）
tooling/ohos/build-hap.sh --debug

# 注入原生库与纯净运行时 (执行 repack 脚本)
# 必须确保 resources/rawfile/dsh-runtime/runtime.zip 以 ZIP_STORED (无压缩) 方式入库
python3 -c "
import zipfile
# 详见 _work/repack_hap_v2.py 逻辑
"
```
产物输出在 `dist/dsh-go-1.0.14-ohos-unsigned-debug-full.hap`。

---

## 六、真机连接与调试诊断手册

### 6.1 HDC 无线调试连接
```bash
# 手机端设置：开启「开发者选项」->「无线调试」-> 查看 IP 和端口
hdc tconn 192.168.2.232:36461
hdc list targets
```

### 6.2 常见真机诊断命令
```bash
# 查看安装包状态与动态库提取情况
hdc shell "bm dump -n ccchimneyyy.dsh.go" | grep -E "versionCode|nativeLibraryPath"

# 调起应用界面
hdc shell "aa start -a EntryAbility -b ccchimneyyy.dsh.go"

# 抓取界面控件与排布
hdc shell "uitest dumpLayout -p /data/local/tmp/layout.json"
hdc shell "cat /data/local/tmp/layout.json"

# 查看 DSH 运行时专项日志
hdc shell "hilog -x -n 1000 | grep DshRuntime"
```

### 6.3 常见启动故障速查表

| 故障现象 / 错误码 | 触发原因 | 解决方法 |
| :--- | :--- | :--- |
| **`ohos_install_required`** | HAP 中没有 `resources/rawfile/dsh-runtime/runtime.zip`，或未安装过运行时 | 使用完整构建包，避免使用仅包含 Flutter 代码的骨架包 |
| **`ohos_payload_missing`** | rawfile 内部是双层嵌套 ZIP，或被 `ZIP_DEFLATED` 压缩导致 `getRawFd()` 读取失败 | 提取内层纯净 `runtime.zip`，并以 `ZIP_STORED` (存储模式) 打入 HAP |
| **`重置还没完成，引擎出错了`** | 上次安装或启动失败，导致 `files/dsh-recovery/reset.json` 停留在 `installing` 阶段 | 安装带有合规 `runtime.zip` 的完整包，App 会自动重新执行安装解包并清除该标记 |
| **`ohos_restart_required`** | 鸿蒙进程模型限制单个进程内 Node 原生库只能运行一次；停止后再次启动需要新进程 | 点击界面上的「重新打开」重启 App 进程 |
