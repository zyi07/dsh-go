# DSH Go Dual-Platform Development & Build Guide

This project is the mobile client for **DeepSeek Harness (DSH)**, covering native application development for both **Android** and **HarmonyOS (Next / API 26+)**. It supports running a patched local DSH engine directly on mobile devices as well as connecting to remote DSH servers via multiple protocols (Direct, Relay, WebRTC, LAN, SSH).

This document details the dual-platform environment setup, dependency matrix, tech stack specifications, core build pipelines, and on-device debugging techniques.

---

## 1. System Architecture & Dual-Platform Differences

```
               ┌──────────────────────────────────────────────┐
               │         Unified Flutter Frontend (UI)        │
               │   Riverpod 2.x · go_router · l10n · Material3 │
               └──────────────────────┬───────────────────────┘
                                      │
            ┌─────────────────────────┴─────────────────────────┐
            ▼                                                   ▼
┌───────────────────────┐                           ┌───────────────────────┐
│    Android Runtime    │                           │   HarmonyOS Runtime   │
├───────────────────────┤                           ├───────────────────────┤
│ • PRoot Linux Sandbox │                           │ • Stage Model ArkTS   │
│ • arm64-v8a Ubuntu    │                           │ • AArch64 libnode.so  │
│ • Standard Node 24 bin│                           │ • libdsh_host Native  │
│ • 113 Common Patches  │                           │ • 144 Specific Patches│
│ • Local HTTP Bridge   │                           │ • ZIP_STORED Rawfile  │
└───────────────────────┘                           └───────────────────────┘
```

### 1.1 Frontend Core Stack
- **Framework & Language**: Flutter 3.47.x / Dart 3.13.x
- **State Management**: `flutter_riverpod` (Notifier / AsyncNotifier)
- **Navigation & Routing**: `go_router`
- **Networking**: `dsh_client` (pure Dart HTTP/SSE, streaming & session deletion); `dsh_remote` (WebRTC, SOCKS5, Direct HTTPS+Token)
- **Localization**: ARB templates compiled via `python app/tool/l10n_merge.py`

### 1.2 Android Runtime Architecture
- **Host**: PRoot sandbox inside Android app container, simulating a Linux rootfs without requiring device root.
- **Payload**: Minimal Debian/Ubuntu rootfs embedding Node.js 24 running `dsh web`.
- **IPC**: App launches PRoot child process and connects via loopback HTTP bridge (`/dsh-go/v1/*`).

### 1.3 HarmonyOS Runtime Architecture
- **Host**: HarmonyOS disallows arbitrary unsigned binaries or generic PRoot; engine runs directly as native shared libraries in-process.
- **Native C/C++ Layer**:
  - `libnode.so`: Node.js 24.22.1 compiled for `aarch64-linux-ohos`, statically linked with libc++.
  - `libdsh_host.so`: Host addon binding ArkTS with the Node runtime instance via N-API.
  - `libdsh_flock.so` & `libdsh_require_builtin.so`: File locking and module loading helpers.
- **Runtime Asset (Rawfile)**:
  - 12,375 files packaged into `dsh-runtime/runtime.zip` via `compose-runtime.py`, located in `resources/rawfile/`.
  - **Critical Constraint**: Must be packaged as **`ZIP_STORED` (uncompressed)** inside the HAP for `resourceManager.getRawFd()` compatibility.

---

## 2. Dependency & Toolchain Matrix

| Component | Android Requirement | HarmonyOS Requirement | Notes |
| :--- | :--- | :--- | :--- |
| **Flutter SDK** | 3.47.7 (Dart 3.13.5) | oh-flutter 3.47.9-ohos-1.0.0 (Dart 3.13.3) | HarmonyOS requires Huawei's Flutter fork |
| **Java JDK** | JDK 17 / JDK 21 | DevEco Studio bundled JBR (JDK 17) | Set `JAVA_HOME` |
| **Build Host OS** | Windows / Linux / macOS | Windows (Packaging) + Linux/WSL (Native libs) | libnode cross-compilation requires Linux |
| **Platform SDK** | Android SDK API 34+ (Build-tools 36.0.0) | DevEco Studio 26+ (SDK 6.1.0.31 / API 26) | Set `DEVECO_SDK_HOME` / `HOS_SDK_HOME` |
| **Build Tooling** | Gradle 8.x | hvigor 6.26.x + ohpm | Bundled in DevEco Studio |
| **C/C++ Toolchain**| Android NDK r26+ | LLVM / Clang 23.1.1 + llvm-project 23 src | Clang 23+ required for Node 24 (crc32b) |
| **Node.js** | Node 24.x / npm 11.x | Node 24.22.1 source + npm 11.9.0 | Used for prefix preparation & patch pins |
| **Bridge Tool** | `adb` | `hdc` (OpenHarmony SDK Toolchains) | Supports USB and Wi-Fi debugging |

---

## 3. Patch System & Coding Standards

### 3.1 DSH Engine Patch System (`runtime/patches/pins.json`)
Hash-pinned patch system (schema 2) ensures byte-level determinism:
- `targetSets.android`: 113 common patches applied to the Android engine rootfs.
- `targetSets.ohos`: 144 patches (113 common + 31 HarmonyOS-specific overrides).
- Verify with:
  ```bash
  python runtime/lib/rtbuild.py patch-dsh --prefix <npm-prefix> --dsh-version 0.2.2-rc.1 --target android
  python runtime/lib/rtbuild.py patch-dsh --prefix <npm-prefix> --dsh-version 0.2.2-rc.1 --target ohos
  ```

---

## 4. Building Android Package

```bash
cd app
flutter pub get
flutter analyze
flutter test
# Build release APK
bash tooling/build-apk.sh --build-name 1.0.13
```
Output: `dist/dsh-go-1.0.13-android-arm64.apk`.

---

## 5. Building HarmonyOS Package

### 5.1 Step 1: Cross-compile Native Libs in Linux / WSL
```bash
# 1. Build static libc++ runtimes
python3 runtime/ohos/node/build-runtimes.py \
  --sdk-native /opt/ohos-sdk/native \
  --clang /opt/llvm-23/bin/clang \
  --source-archive /opt/llvm-project-23.1.1.src.tar.xz \
  --work /tmp/rt-work --output /tmp/rt-out --jobs 6

# 2. Cross-compile libnode.so
python3 runtime/ohos/node/build-node.py \
  --sdk-native /opt/ohos-sdk/native \
  --clang /opt/llvm-23/bin/clang \
  --cxx-runtime /tmp/rt-out \
  --source-archive /opt/node-v24.22.1.tar.xz \
  --host-node /usr/bin/node \
  --work /tmp/node-work --output /tmp/node-out --jobs 6

# 3. Compile native libraries (libdsh_host, libdsh_flock, libdsh_require_builtin)
python3 runtime/ohos/native/build-hap-libs.py ...

# 4. Compose 12,375-file runtime archive
python3 runtime/ohos/package/prepare-inputs.py --target ohos ...
python3 runtime/ohos/package/compose-runtime.py --target ohos ...
```

### 5.2 Step 2: Build HAP & Package
On Windows:
```bash
tooling/ohos/build-hap.sh --debug
# Repack HAP ensuring resources/rawfile/dsh-runtime/runtime.zip is stored with ZIP_STORED (0)
```
Output: `dist/dsh-go-1.0.13-ohos-unsigned-debug-full.hap`.

---

## 6. On-Device Debugging & Troubleshooting

### 6.1 Wireless HDC Connection
```bash
hdc tconn 192.168.2.232:36461
hdc list targets
```

### 6.2 Common Issues & Resolutions

| Error / Symptom | Root Cause | Resolution |
| :--- | :--- | :--- |
| **`ohos_install_required`** | Missing `resources/rawfile/dsh-runtime/runtime.zip` in HAP | Build and deploy the full HAP package rather than the skeleton HAP |
| **`ohos_payload_missing`** | Nested double-ZIP or `ZIP_DEFLATED` rawfile causing `getRawFd()` failure | Extract inner `runtime.zip` and package with `ZIP_STORED` (uncompressed) |
| **Reset incomplete / `reset.json` stuck in `installing`** | Previous installation failed during runtime setup | Install full package; recovery automatically resumes installation and clears state |
| **`ohos_restart_required`** | HarmonyOS single-process lifecycle limitation (Node native host runs once per process) | Tap "Reopen App" on screen |
