# Notices and attribution

This repository contains a derivative work. The notices below are part of the
license terms for the upstream material and must be kept with any redistribution.

## 1. Oyama's HRT Tracker (upstream project)

This app is a **rewrite** of **Oyama's HRT Tracker**, distributed under the MIT
License:

> MIT License
>
> Copyright (c) 2025 Joseph Smirnova Oyama

- Upstream repository: <https://github.com/xunxunProjects/Oyama-s-HRT-Tracker>
- Author: Joseph Smirnova Oyama (GitHub: [@SmirnovaOyama](https://github.com/SmirnovaOyama))

The upstream web client (`src/`, `logic.ts`, `public/`, `tests/`), its Tauri
shell, the Cloudflare worker and the documentation are **not** included in this
repository; only the Android rewrite lives here. The rewrite is not a fork of
the upstream UI code — the interface was rewritten in Flutter, the
pharmacokinetic model was translated to Rust, and the server components were
removed — but it reuses the upstream algorithms, the storage and backup formats,
the design language and the translated copy, so it is a derivative work and
remains under the same MIT License.

## 2. HRT-Recorder-PKcomponent-Test (pharmacokinetic model)

The estradiol model implemented in `rust/src/engine.rs` follows
`PKcore.swift` and `PKparameter.swift` from:

- Repository: <https://github.com/LaoZhong-Mihari/HRT-Recorder-PKcomponent-Test>
- Author: [@LaoZhong-Mihari](https://github.com/LaoZhong-Mihari)

The three-compartment structure, the two-part injection depot kinetics and the
sublingual absorption tiers come from that project. Upstream's own README asks
that this credit stay visible, and it is shown in the app under
Settings → Credits.

## 3. Changes made in this rewrite

- Material 3 user interface (dynamic colour, adaptive navigation, predictive
  back) replacing the React client.
- The model ported to Rust and shipped as a plain `libhrt_core.so` behind a JSON
  C ABI, so other clients can reuse it without a Dart runtime.
- SQLite as the only store; the Cloudflare worker, the community vote and every
  network call removed. The Android manifest declares no network permission.
- Local notifications driven by the modelled curve, plus a boot receiver and an
  exact-alarm fallback.
- Backup import/export rewritten in Dart, compatible with the four historical
  shapes, including the encrypted envelope.
- Small fixes to the ported behaviour: the core accepts both `doseMG` and
  `doseMg`; the "prediction curve" setting only controls the chart's look-ahead
  as upstream intended; the overview repaints on a clock.

## 4. License

MIT — see [LICENSE](LICENSE). The upstream copyright notice is preserved there
and applies to the upstream-derived material; the Android rewrite is
copyright its contributors under the same terms.

Third-party Dart, Rust and Android packages are used under their own licenses;
the resolved set is listed in `pubspec.lock` and `rust/Cargo.lock`.
