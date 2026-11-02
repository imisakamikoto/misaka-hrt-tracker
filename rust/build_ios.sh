#!/usr/bin/env bash
# Builds the PK core for iOS as a static library.
#
# iOS refuses to load a dylib that is not signed as part of the bundle, so the
# Dart side uses `DynamicLibrary.process()` and the archive is linked straight
# into Runner. A device slice and a simulator slice cannot share a link, which
# is why the simulator result is lipo'd into its own directory and both are
# referenced from `ios/Flutter/*.xcconfig`.
set -euo pipefail
cd "$(dirname "$0")"

# cargo lives outside the PATH of a plain non-login shell on macOS.
export PATH="${HOME}/.cargo/bin:${PATH}"

# The symbol table has to survive: `DynamicLibrary.process()` resolves
# `hrt_abi_version` and friends from the executable at run time.
export CARGO_PROFILE_RELEASE_STRIP=none

rustup target add aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios

cargo build --release --target aarch64-apple-ios
cargo build --release --target aarch64-apple-ios-sim
cargo build --release --target x86_64-apple-ios

mkdir -p target/ios-sim/release
lipo -create \
  target/aarch64-apple-ios-sim/release/libhrt_core.a \
  target/x86_64-apple-ios/release/libhrt_core.a \
  -output target/ios-sim/release/libhrt_core.a

echo
echo "Device:    target/aarch64-apple-ios/release/libhrt_core.a"
echo "Simulator: target/ios-sim/release/libhrt_core.a"
