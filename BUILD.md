# Building all three platforms

Everything is local: no server, no cloud project, no account.

One Flutter project produces the Android APK, the iOS IPA and the Windows MSI.
Only the Rust core differs per platform, because each OS has its own rule about
native libraries: Android loads a `.so`, iOS only links a static archive into
the bundle, Windows loads a `.dll`.

## Requirements

| Platform | Needs |
|---|---|
| All | Flutter 3.47+ (Dart 3.13+), Rust 1.99+ |
| Android | Android SDK (API 36), JDK 17, `cargo-ndk` |
| iOS | macOS with Xcode 16+, CocoaPods |
| Windows | Visual Studio 2022 (Desktop C++), WiX Toolset 3 |

```sh
rustup target add aarch64-linux-android armv7-linux-androideabi x86_64-linux-android
cargo install cargo-ndk
flutter pub get
```

## Android

```sh
flutter build apk --release                    # universal, all three ABIs
flutter build apk --release --split-per-abi    # one APK per ABI
```

Finished files land in `build/app/outputs/flutter-apk/`.

The Gradle task `buildRustCore` cross-compiles `rust/` into
`android/app/src/main/jniLibs/{arm64-v8a,armeabi-v7a,x86_64}/libhrt_core.so`
before packaging. If `cargo` is not installed the task is skipped and the
libraries already in `jniLibs` are packaged instead.

To build the Rust core by hand:

```sh
cd rust
cargo ndk -t arm64-v8a -t armeabi-v7a -t x86_64 -o ../android/app/src/main/jniLibs build --release
```

## iOS

```sh
bash rust/build_ios.sh          # device + simulator archives
flutter build ios --release --no-codesign
```

`build_ios.sh` builds `aarch64-apple-ios` for hardware and lipos
`aarch64-apple-ios-sim` + `x86_64-apple-ios` into `rust/target/ios-sim`. Both
paths are named in `ios/Flutter/Debug.xcconfig` and `Release.xcconfig`, which
use `-force_load` so the linker keeps every symbol the app looks up at run time
through `DynamicLibrary.process()`. The archive is built with
`CARGO_PROFILE_RELEASE_STRIP=none` for the same reason — a stripped archive
loses the names `dlsym` needs.

To make an installable IPA you need a signing identity. Without one, zip the
unsigned bundle and re-sign it on the other side (AltStore, Sideloadly, Xcode):

```sh
mkdir -p Payload
cp -R build/ios/iphoneos/Runner.app Payload/
zip -qry Misaka-hrt-ios.ipa Payload
```

## Windows

```sh
cargo build --release --manifest-path rust/Cargo.toml   # rust/target/release/hrt_core.dll
flutter build windows --release                          # build/windows/x64/runner/Release
powershell -ExecutionPolicy Bypass -File packaging/windows/build_msi.ps1 -Version 1.1.0
```

`windows/CMakeLists.txt` copies `hrt_core.dll` next to `hrt_tracker.exe` after
the build, and the Dart side opens it by absolute path. `build_msi.ps1` runs
WiX `heat` over the release folder (so no DLL can be forgotten), then `candle`
and `light` link `dist/Misaka-hrt-<version>-windows-x64.msi`.

## Continuous integration

`.github/workflows/build-installers.yml` does the iOS and Windows halves on
GitHub runners: `macos-14` for the unsigned IPA, `windows-latest` for the MSI.
Both are attached to the run as artifacts; pushing a `v*` tag starts it.

## Tests

```sh
flutter test          # domain, supply, backup and string tests
cd rust && cargo test # PK model and calibration
```

If `flutter test` or `flutter analyze` fails with a WebSocket error while
connecting to the tester, a proxy environment variable is in the way:

```sh
env -u http_proxy -u https_proxy -u all_proxy flutter test
```

## Signing

The Android release build currently uses the debug key, which is enough to
install the APK on your own phone. Before publishing anywhere, create a
keystore and point `android/app/build.gradle.kts` at it. The iOS build is
unsigned for the same reason: no certificate is shipped with the repository.

## Package

| Platform | Identifier |
|---|---|
| Android | `jp.misaka.hrt` — minSdk 24, targetSdk 36, no internet permission |
| iOS | `jp.misaka.hrt` — iOS 15+ |
| Windows | `jp.misaka.hrt` — x64, Windows 10 1809+ |
