#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
JOBS="$(sysctl -n hw.logicalcpu 2>/dev/null || echo 4)"
MINGW_DIR="$ROOT/toolchains/llvm-mingw-20260421-ucrt-macos-universal"

cd "$ROOT"
git submodule sync --recursive
git submodule update --init --recursive --jobs "$JOBS"

mkdir -p toolchains
if [ ! -x "$MINGW_DIR/bin/aarch64-w64-mingw32-clang" ]; then
    curl --fail --location --retry 3 \
      https://github.com/mstorsjo/llvm-mingw/releases/download/20260421/llvm-mingw-20260421-ucrt-macos-universal.tar.xz \
      | tar -xJ -C toolchains
fi
export PATH="$MINGW_DIR/bin:/opt/homebrew/opt/llvm/bin:/usr/local/opt/llvm/bin:$PATH"

echo "::group::Generate Wine build headers"
mkdir -p wine/build-macos
if [ ! -f wine/build-macos/include/config.h ]; then
    (cd wine/build-macos && ../configure --enable-win64 --without-alsa --without-cups \
        --without-dbus --without-fontconfig --without-freetype --without-gettext \
        --without-gnutls --without-gstreamer --without-oss --without-pulse \
        --without-sdl --without-udev --without-v4l2 --without-wayland --without-x)
fi
make -C wine/build-macos -j"$JOBS" \
    include/objidlbase.h include/dwrite.h include/dwrite_3.h

mkdir -p wine/build-arm64ec
if [ ! -f wine/build-arm64ec/include/config.h ]; then
    (cd wine/build-arm64ec && ../configure --host=aarch64-w64-mingw32 \
        --enable-archs=arm64ec --with-wine-tools=../build-macos \
        --without-alsa --without-cups --without-dbus --without-fontconfig \
        --without-freetype --without-gettext --without-gnutls \
        --without-gstreamer --without-oss --without-pulse --without-sdl \
        --without-udev --without-v4l2 --without-wayland --without-x)
fi
make -C wine/build-arm64ec -j"$JOBS" \
    include/objidlbase.h include/dwrite.h include/dwrite_3.h
echo "::endgroup::"

echo "::group::Build FEXCore for iOS"
FEX_IOS_COMPAT="$ROOT/toolchains/fex-ios-compat.h"
if [ ! -f "$FEX_IOS_COMPAT" ]; then
    printf '%s\n' \
      '#pragma once' \
      '#include <cstddef>' \
      '#include <cstdint>' \
      'struct MEMORY_BASIC_INFORMATION {' \
      '  void* BaseAddress;' \
      '  std::size_t RegionSize;' \
      '  std::uint32_t Protect;' \
      '  std::uint32_t State;' \
      '  std::uint32_t Type;' \
      '};' \
      'using LPCVOID = const void*;' \
      'inline constexpr std::uint32_t MEM_IMAGE = 0x01000000;' \
      'inline constexpr std::uint32_t MEM_MAPPED = 0x00040000;' \
      'inline std::size_t VirtualQuery(LPCVOID, MEMORY_BASIC_INFORMATION*, std::size_t) { return 0; }' \
      > "$FEX_IOS_COMPAT"
fi
cmake -S FEX -B FEX/build-ios -G Ninja \
    -DCMAKE_SYSTEM_NAME=iOS \
    -DCMAKE_SYSTEM_PROCESSOR=arm64 \
    -DCMAKE_OSX_SYSROOT=iphoneos \
    -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=17.0 \
    -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_TESTING=OFF \
    -DBUILD_FEX_LINUX_TESTS=OFF \
    -DBUILD_FEXCONFIG=OFF \
    -DBUILD_THUNKS=OFF \
    -DENABLE_LTO=OFF \
    -DENABLE_GDB_SYMBOLS=OFF \
    -DENABLE_OFFLINE_TELEMETRY=OFF \
    -DCMAKE_C_FLAGS="-DFEX_IOS_HOST=1" \
    -DCMAKE_CXX_FLAGS="-DFEX_IOS_HOST=1 -include $FEX_IOS_COMPAT" \
    -DTUNE_CPU=generic
cmake --build FEX/build-ios --target FEXCore FEXCore_Base JemallocLibs -j "$JOBS"
echo "::endgroup::"

echo "::group::Build LLVM 15 libraries for iOS"
LLVM_SRC="$ROOT/toolchains/llvm-project/llvm"
LLVM_HOST="$ROOT/toolchains/llvm-host-build"
LLVM_IOS="$ROOT/toolchains/llvm-ios-build"
if [ ! -f "$LLVM_SRC/CMakeLists.txt" ]; then
    git clone --depth 1 --branch llvmorg-15.0.7 \
      https://github.com/llvm/llvm-project.git "$ROOT/toolchains/llvm-project"
fi
if ! grep -q 'Darwin|iOS' "$LLVM_SRC/cmake/modules/AddLLVM.cmake"; then
    sed -i '' 's/MATCHES "Darwin"/MATCHES "Darwin|iOS"/' "$LLVM_SRC/cmake/modules/AddLLVM.cmake"
fi
if [ ! -x "$LLVM_HOST/bin/llvm-tblgen" ]; then
    cmake -S "$LLVM_SRC" -B "$LLVM_HOST" -G Ninja \
      -DCMAKE_BUILD_TYPE=Release -DLLVM_ENABLE_PROJECTS= \
      -DLLVM_INCLUDE_TESTS=OFF -DLLVM_INCLUDE_EXAMPLES=OFF -DLLVM_INCLUDE_BENCHMARKS=OFF
    cmake --build "$LLVM_HOST" --target llvm-tblgen -j "$JOBS"
fi
cmake -S "$LLVM_SRC" -B "$LLVM_IOS" -G Ninja \
    -DCMAKE_SYSTEM_NAME=iOS \
    -DCMAKE_OSX_SYSROOT=iphoneos \
    -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=17.0 \
    -DCMAKE_BUILD_TYPE=Release \
    -DLLVM_TABLEGEN="$LLVM_HOST/bin/llvm-tblgen" \
    -DLLVM_BUILD_UTILS=OFF -DLLVM_BUILD_TOOLS=OFF \
    -DLLVM_INCLUDE_TOOLS=OFF -DLLVM_ENABLE_LTO=OFF \
    -DLLVM_BUILD_LLVM_DYLIB=OFF \
    -DLLVM_INCLUDE_TESTS=OFF -DLLVM_INCLUDE_EXAMPLES=OFF \
    -DLLVM_INCLUDE_BENCHMARKS=OFF -DLLVM_ENABLE_TERMINFO=OFF \
    -DLLVM_ENABLE_ZLIB=OFF -DLLVM_ENABLE_ZSTD=OFF \
    -DLLVM_TARGETS_TO_BUILD=AArch64
cmake --build "$LLVM_IOS" --target llvm-libraries -j "$JOBS"
echo "::endgroup::"

echo "::group::Build remaining iOS static libraries"
if [ ! -d research/freetype ]; then
    git clone --depth 1 --branch VER-2-13-3 https://github.com/freetype/freetype.git research/freetype
fi
bash build/freetype-ios/build.sh
bash build/gnutls-ios/build.sh
bash build/ntdll-unix/build.sh
bash build/win32u-unix/build.sh
bash build/wineserver/build.sh

if [ ! -e research/dxmt/toolchains ]; then
    ln -s ../../toolchains research/dxmt/toolchains
fi
bash build/dxmt-ios/build.sh
xcrun -sdk iphoneos libtool -static -o build/dxmt-ios/libdxmt_combined.a \
    build/dxmt-ios/obj/*.o toolchains/llvm-ios-build/lib/*.a
cp build/dxmt-ios/libdxmt_combined.a app/Madeira/
echo "::endgroup::"

required=(
  FEX/build-ios/FEXCore/Source/libFEXCore.a
  FEX/build-ios/FEXCore/Source/libFEXCore_Base.a
  FEX/build-ios/FEXCore/Source/libJemallocLibs.a
  app/Madeira/libntdll_unix.a
  app/Madeira/libwin32u_unix.a
  app/Madeira/libwineserver.a
  app/Madeira/libdxmt_combined.a
)
for file in "${required[@]}"; do
    test -s "$file" || { echo "Missing required library: $file"; exit 1; }
done
