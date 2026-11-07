# 接手说明：dsh-Go 直连服务器 + 鸿蒙

这份文件只存在于本仓库的 `handoff` 分支，不进入上游。

## 分支

| 分支 | 提交 | 内容 |
|---|---|---|
| `main` | `d5ad25c5` | 上游 1.0.12 基线（`main` 原样） |
| `feat/direct-host` | `cef4fd1d` | **Android**：1.0.12 + 直连服务器（29 文件 +2726/−17） |
| `feat/direct-host-ohos` | `4e509fa9` | **鸿蒙**：`claude/harmonyos-ohos`（8ab20fb5）+ 同一份直连改动 |
| `wip/merge-main-ohos` | `d2cf7893` | 把 1.0.12 并入鸿蒙分支的合并尝试，**未解决** runtime pins 取舍 |

## 已完成并验证

- `flutter analyze`：No issues found
- 直连 4 个测试文件 53 项 + 既有 `hosts_state`/`remote_widgets` 48 项 = **101 项全绿**（在 `feat/direct-host-ohos` 上跑）
- APK（Android，arm64 release）已构建：`1.0.11` / versionCode 11070830，Debug 证书签名
- 鸿蒙侧 ArkTS **零改动**：`HostKind` 不出现在 `.ets`；`module.json5` 已有 `ohos.permission.INTERNET`、`GET_NETWORK_INFO`

## 未完成（需要你接手）

1. **HAP 构建**：本容器是 aarch64 Linux，oh-flutter 的定制 Dart SDK 没有 Linux 版
   （`flutter --version` 报 `Member not found: 'ohosArm64'`），OBS 也只发布
   `darwin-x64` / `linux-x64` 的 AOT 工具（`linux-arm64` 404）。需要在 macOS arm64 上：
   ```bash
   FLUTTER_OHOS=/path/to/flutter-ohos/bin/flutter \
   DSH_OHOS_NATIVE_LIBS=/path/to/hap-libs/arm64-v8a \
   DSH_NODE_HEADERS=/path/to/node-v24.22.1/src \
   DSH_OHOS_RUNTIME=/path/to/dsh-runtime-rawfile.zip \
     tooling/ohos/build-hap.sh
   ```
   `hap-libs` 需要先按 `runtime/ohos/node/BUILD.md` 用 LLVM 23.1.1 编 Node；
   `dsh-runtime-rawfile.zip` 来自 `runtime/ohos/package/compose-runtime.py`。
   装到华为手机还需要你的签名 profile/p12。
2. **`wip/merge-main-ohos`**：`runtime/patches/pins.json` 冲突（鸿蒙分支 schema 2 +
   `targetSets`，main 还是 schema 1），需要维护者决定补丁取舍后再合。
3. **golden**：`test/remote/remote_golden_test.dart` 因新增「直连服务器」分区需重新生成
   （本容器字体替换导致全部 golden 不一致，无法生成可信图片）。
4. **真机验证**：容器无设备/无 KVM，只在用户手机上验证过连接可用。

## 本机环境提示

- 跑测试必须先 `export DSH_TEST_FONT_DIR=<含 NotoSansCJK-{Regular,Bold,Light}.ttc 的目录>`，
  否则所有 app 测试以 `Test font missing` 失败。
- 容器里额外装的 `.toolchain/`（Flutter、Flutter-ohos、SDK 覆盖层、box64 代跑 AOT）
  **不在仓库内**，你本地用自己环境即可。
