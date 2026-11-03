# 参与贡献

谢谢愿意搭把手。这是一个个人维护的离线应用：记录用药、把记录画成浓度曲线。
凡是让它更准确、更稳、更好用的事都欢迎 —— 一个算错的常数、一句说不清的报错、
一段翻译、一次无障碍改进。

## 动手之前

| 你的情况 | 建议 |
|---|---|
| 数字不对、崩溃、界面错位 | 直接开 [issue](https://github.com/imisakamikoto/misaka-hrt-tracker/issues/new?template=bug_report.yml)，附上能复现的操作和你看到的实际结果 |
| 想要一个新功能 | 先开 issue 说清楚"你想回答什么问题"，再动手。避免写完发现方向不对 |
| 文案、翻译、README 的错别字 | 直接提 PR，不用先开 issue |
| 自己的用药方案该怎么调 | 请问医生，不要在 issue 里问 —— 这里没有人能做临床判断 |

**请不要**把一个 reformat、一次依赖升级和一个 bug 修复塞进同一个 PR。一个 PR 一个理由。

## 环境

```bash
git clone https://github.com/imisakamikoto/misaka-hrt-tracker
cd misaka-hrt-tracker
flutter pub get
flutter test          # Dart 侧
cargo test --manifest-path rust/Cargo.toml   # 模型侧
```

Flutter 3.x + Rust 1.75 以上。三端各自的依赖（Xcode、MSVC + WiX、NDK）见
[BUILD.md](BUILD.md)。只改 Dart 的话，不需要装 NDK。

## 这个项目守着几条线

不是风格偏好，是它敢把数据留在本机的理由：

1. **不联网。** Android 版不申请 `INTERNET` 权限；新增依赖如果会联网，先说清楚为什么。
2. **不留后门数据。** 记录、检验、备份都只在本机；没有账号、没有上报、没有埋点。
3. **模型层不做 I/O。** `rust/` 只做数学，时间由调用方传入（`nowH`）。需要知道"现在几点"的改动属于 Dart 层。
4. **界面上写的数字必须来自模型。** 不要为了好看去平滑或补点。
5. **不确定的事说"不确定"。** 模型没覆盖的酯、路径、剂型，要显示为"未建模"，而不是按 0 算。

## 提交 PR

1. Fork，从 `main` 切分支。
2. 能先写测试就先写（`test/domain_test.dart`、`test/engine_test.dart`，或 `rust/` 里的 `#[test]`）。
3. `flutter analyze` 与 `cargo fmt` 跑一遍。
4. 改了行为就在 PR 里写清楚改了什么、为什么；截图或录屏对界面改动很有帮助。
5. 等 CI 绿。CI 会构建 Android 三 ABI、未签名 IPA 与 MSI —— 第一次跑要十几分钟。

## 翻译

界面文案在 `lib/` 里，目前只有中文。要加语言的话，先开 issue 说一下范围（是只加界面文案，
还是连模型输出的说明一起），避免大改动白做。

## 许可

本项目以 MIT 许可证发布（见 [LICENSE](LICENSE)），上游是 Joseph Smirnova Oyama 的
[Oyama's HRT Tracker](https://github.com/xunxunProjects/Oyama-s-HRT-Tracker)。
提交 PR 即表示你同意以同样的许可证发布你的改动。
