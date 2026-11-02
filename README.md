# Misaka hrt记录器

离线运行的 Android HRT 记录与血药浓度估算应用。界面用 Flutter（Material 3），药代动力学模型用 Rust 写成独立的 `libhrt_core.so`，所有数据只保存在手机本地：没有账号、没有服务器，**APK 不申请任何网络权限**。

**English**: an offline HRT tracker and concentration modeller for Android, built with Flutter (Material 3) and a Rust pharmacokinetic core. Everything stays on the device; the release build requests no network permission at all.

---

## 来源与致谢 / Credits

本项目是 **[Oyama's HRT Tracker](https://github.com/xunxunProjects/Oyama-s-HRT-Tracker)** 的 Android 重写版本，原作由 **Joseph Smirnova Oyama（[@SmirnovaOyama](https://github.com/SmirnovaOyama)）** 以 MIT 许可证发布。原始的 Web / Tauri 客户端代码仍原样保留在本仓库根目录，Android 实现位于 [`flutter_app/`](flutter_app)。

> This is an Android rewrite of **Oyama's HRT Tracker** by **Joseph Smirnova Oyama**, used and redistributed under the MIT License. The original web/Tauri client is kept unmodified at the repository root; the rewrite lives in [`flutter_app/`](flutter_app).

雌二醇的药代动力学模型来自 **[@LaoZhong-Mihari](https://github.com/LaoZhong-Mihari)** 的 [HRT-Recorder-PKcomponent-Test](https://github.com/LaoZhong-Mihari/HRT-Recorder-PKcomponent-Test)（`PKcore.swift` / `PKparameter.swift`）：三室结构、双相注射储库动力学与舌下吸收档位均沿用该模型。

详见 [NOTICE.md](NOTICE.md)。

## 下载 / Download

最新版本在 [Releases](https://github.com/imisakamikoto/misaka-hrt-tracker/releases)：

| 文件 | 适用 |
|---|---|
| `Misaka-hrt-arm64-v8a.apk` | 绝大多数手机（推荐） |
| `Misaka-hrt-armeabi-v7a.apk` | 老款 32 位机型 |
| `Misaka-hrt-x86_64.apk` | 模拟器 |

Android 9（API 28）及以上。当前用 debug key 签名，直接安装即可；上架商店需要自建 keystore。

## 功能

- **记录**：注射、口服、舌下、凝胶、贴片，凝胶部位、贴片释放率与佩戴时长、舌下含服档位；快捷剂量与模板；按天分组的历史与热力图。
- **估算**：目标带、当前浓度、CPA / 睾酮曲线，1 / 3 / 7 / 30 天窗口，拖动读数；此刻之后按用药计划画虚线预测。
- **校准**：MIPD、扩展卡尔曼（EKF）、OU-Kalman，前向 / 回溯两种历史模式。
- **检验**：录入结果（pg/mL、pmol/L、ng/dL、nmol/L），叠加到曲线并与模型对账。
- **计划与库存**：周期性方案、今日待服、下一次服药；库存剩余与用完日期。
- **提醒**：模型预测浓度跌破目标带下沿前提醒服药（仅非注射方案），可选的到点提醒，精确闹钟不可用时自动降级；重启后由 `BOOT_COMPLETED` 接收器恢复。
- **备份**：完整备份、仅记录、加密备份（PBKDF2-SHA256 600k + AES-256-GCM）、只读快照；导入兼容本项目四种历史格式，可合并或替换。
- **外观**：Material 3、Material You 动态取色、浅色/深色/单色、简体/繁体/粤语/英/日/韩/土耳其语。

## 构建

```bash
cd flutter_app
rustup target add aarch64-linux-android armv7-linux-androideabi x86_64-linux-android
cargo install cargo-ndk            # 一次性
flutter pub get
flutter build apk --release --split-per-abi
```

Gradle 的 `buildRustCore` 任务会在 `preBuild` 前用 cargo-ndk 交叉编译 `flutter_app/rust`，把 `libhrt_core.so` 放进 `jniLibs`；没装 Rust 工具链时会跳过、复用已有 `.so`。细节见 [`flutter_app/BUILD.md`](flutter_app/BUILD.md)。

## 测试

```bash
cd flutter_app/rust && cargo test          # 8 项：解析、配对、量级
cd flutter_app && flutter test             # 22 项：领域逻辑、备份、Dart ⇄ Rust 端到端
```

## 仓库结构

```
flutter_app/            Android 应用
  lib/                  Flutter 界面与状态
  rust/                 药代动力学内核（cdylib / staticlib / rlib）
  android/              Gradle、Manifest、BootReceiver、jniLibs
src/ logic.ts ...       上游 Web 客户端（保留，未改动）
README.UPSTREAM.md      上游 README（原文）
NOTICE.md               来源与第三方声明
LICENSE                 MIT
```

## 免责声明

本应用给出的是**模型估算值，不是医疗建议**，也不能替代化验。用药请遵医嘱。

## 许可证

MIT，见 [LICENSE](LICENSE)。上游版权归 Joseph Smirnova Oyama 所有，Android 重写部分版权归本项目贡献者所有。
