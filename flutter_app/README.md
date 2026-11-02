# Misaka hrt记录器 — Android app

离线 HRT 记录与浓度估算的 Android 实现：Flutter（Material 3）界面 + Rust 药代动力学内核（`libhrt_core.so`）。所有数据只存在本机 SQLite，没有账号、没有服务器，release 包不申请网络权限。

- 包名：`jp.misaka.hrt`
- 最低版本：Android 9（API 28）
- 应用名（启动器显示）：Misaka hrt记录器

## 目录

```
lib/            界面与状态（Material 3，5 个 tab）
  core/         主题、多语言、通知、开机自启、FFI 桥
  data/         sqlite 存储、备份编解码、数据模型
  state/        AppState（单一数据源 + 定时重算）
  ui/           页面与图表
rust/           药代动力学内核（cdylib / staticlib / rlib，JSON over C ABI）
android/        Gradle、Manifest、BootReceiver、jniLibs
test/           领域逻辑、备份、Dart ⇄ Rust 端到端测试
tool/           诊断脚本（例如用应用自己的解码器检查备份文件）
```

## 构建

```bash
rustup target add aarch64-linux-android armv7-linux-androideabi x86_64-linux-android
cargo install cargo-ndk
flutter pub get
flutter build apk --release --split-per-abi
```

细节见 [BUILD.md](BUILD.md)。Gradle 的 `buildRustCore` 任务会在 `preBuild` 前重新编译 Rust 并投放 `.so`；没有 Rust 工具链时会跳过。

## 测试

```bash
cd rust && cargo test        # 引擎：解析、贴片配对、量级
flutter test                 # 领域逻辑 + 备份 + 真实 FFI 调用
```

> 本机注意：`flutter analyze` / `flutter test` 需先清掉代理环境变量，  
> 否则会卡在 `WebSocket upgrade request`；分析器在含中文与空格的路径下会崩，  
> 需要把 `lib test pubspec.* .dart_tool` 复制到纯 ASCII 目录再跑。

## 来源与致谢

本应用是 **Oyama's HRT Tracker** 的 Android 重写版本，原项目由  
**Joseph Smirnova Oyama（[@SmirnovaOyama](https://github.com/SmirnovaOyama)）**  
以 MIT 许可证发布：<https://github.com/xunxunProjects/Oyama-s-HRT-Tracker>。

雌二醇模型沿用 **[@LaoZhong-Mihari](https://github.com/LaoZhong-Mihari)** 的  
[HRT-Recorder-PKcomponent-Test](https://github.com/LaoZhong-Mihari/HRT-Recorder-PKcomponent-Test)  
（`PKcore.swift` / `PKparameter.swift`）。

完整声明见仓库根目录的 [NOTICE.md](../NOTICE.md) 与 [LICENSE](../LICENSE)。

