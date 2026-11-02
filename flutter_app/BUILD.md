# Building the APK

Everything is local: no server, no cloud project, no account.

## Requirements

- Flutter 3.47+ (Dart 3.13+) and the Android SDK (API 36, build-tools 36)
- JDK 17
- Rust with the Android targets, plus `cargo-ndk`:

```sh
rustup target add aarch64-linux-android armv7-linux-androideabi x86_64-linux-android
cargo install cargo-ndk
```

## One command

```sh
cd flutter_app
flutter build apk --release            # universal, all three ABIs
flutter build apk --release --split-per-abi   # smaller, one APK per ABI
```

Finished files land in `build/app/outputs/flutter-apk/`; copies with readable
names are kept in `dist/`.

The Gradle task `buildRustCore` cross-compiles `rust/` into
`android/app/src/main/jniLibs/{arm64-v8a,armeabi-v7a,x86_64}/libhrt_core.so`
before packaging. If `cargo` is not installed the task is skipped and the
libraries already in `jniLibs` are packaged instead.

To build the Rust core by hand:

```sh
cd rust
cargo ndk -t arm64-v8a -t armeabi-v7a -t x86_64 -o ../android/app/src/main/jniLibs build --release
```

## Tests

```sh
flutter test          # domain, supply, backup and string tests
cargo test            # PK model and calibration
```

If `flutter test` or `flutter analyze` fails with a WebSocket error while
connecting to the tester, a proxy environment variable is in the way:

```sh
env -u http_proxy -u https_proxy -u all_proxy flutter test
```

## Signing

The release build currently uses the debug key, which is enough to install the
APK on your own phone. Before publishing anywhere, create a keystore and point
`android/app/build.gradle.kts` at it.

## Package

`com.oyama.hrt_tracker` — minSdk 24, targetSdk 36, no internet permission.
