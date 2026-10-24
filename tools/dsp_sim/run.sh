#!/bin/sh
# Build sim.cpp for the x86_64 emulator with the NDK clang and run it there.
NDK=${NDK:-/c/dev/android-sdk/ndk/28.2.13676358/toolchains/llvm/prebuilt/windows-x86_64/bin}
DEV=${DEV:-emulator-5554}
cd "$(dirname "$0")" || exit 1
"$NDK/clang++.exe" --target=x86_64-linux-android30 -O2 -std=c++17 -static-libstdc++ \
  -I ../../android/app/src/main/cpp sim.cpp -o sim || exit 1
MSYS_NO_PATHCONV=1 adb -s "$DEV" push sim /data/local/tmp/sim >/dev/null
MSYS_NO_PATHCONV=1 adb -s "$DEV" shell chmod 755 /data/local/tmp/sim
MSYS_NO_PATHCONV=1 adb -s "$DEV" shell /data/local/tmp/sim
