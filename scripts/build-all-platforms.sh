#!/bin/bash
#
# Builds sevenzipjbinding-all-platforms-<version>.jar (12 native platforms) on a macOS host.
#
#  - Mac (universal x86_64 + arm64): native build, flags from .github/workflows/macos.yml plus
#    CMAKE_OSX_DEPLOYMENT_TARGET=14.0 (the published 23.01-2.2 dylib has minos 14.0).
#  - Linux glibc + Windows: dockcross images (Linux 20201222-0217db3, Windows 20201116-0216d09), whose
#    toolchains match the compilers recorded in the published 23.01-2.2 natives (each build checks the
#    GCC version). Windows needs the older tag: from 20201222 on, MXE ships GCC 10.2.0 instead of 9.2.0.
#  - Linux-amd64-musl: native build in alpine:3.12 (GCC 9.3.0, as upstream).
#  - Linux-arm64-musl, Linux-armv7-musl: Bootlin musl 2020.02 cross-toolchains (GCC 8.4.0, as upstream).
#  - Merge: scripts/build-multiplatform-release.sh (needs GNU tools, so it runs in a Linux container).
#
# Requirements: macOS with Xcode command line tools, a local JDK 8 (/usr/libexec/java_home -v 1.8),
# python3, curl, podman with a running machine. Network access for downloads and image pulls.
#
# Usage:
#   build-all-platforms.sh [build]   builds the platforms not built yet, then merges all of them.
#                                    A platform counts as built when build-<platform>/ holds its zip;
#                                    a build directory without the zip is removed and rebuilt.
#                                    Sources are not compared: after changing them run "cleanup" first
#                                    (or delete the affected build-<platform> directories).
#   build-all-platforms.sh cleanup   removes everything: build-* directories, WORK_DIR and CACHE_DIR
#                                    (podman images are kept)
#
# Environment:
#   WORK_DIR       work directory, recreated on every build run (default: $HOME/sevenzip-cross)
#   CACHE_DIR      downloads, CMake venv and apk/apt package caches, kept between build runs
#                  (default: $HOME/.cache/sevenzipjbinding-build)
#   RUN_MAC_TESTS  set to 1 to run ctest for the Mac build (slow)
#
# Result: $WORK_DIR/out/sevenzipjbinding-all-platforms-<version>.jar

set -euo pipefail
shopt -s nullglob

SRC="$(cd "$(dirname "$0")/.." && pwd)"
W="${WORK_DIR:-$HOME/sevenzip-cross}"
CACHE="${CACHE_DIR:-$HOME/.cache/sevenzipjbinding-build}"
VERSION="$(sed -n 's/^SET(SEVENZIPJBINDING_VERSON \(.*\))$/\1/p' "$SRC/CMakeLists.txt")"

DOCKCROSS_TAG=20201222-0217db3
DOCKCROSS_WINDOWS_TAG=20201116-0216d09
JDK8_LINUX_X64_URL=https://corretto.aws/downloads/latest/amazon-corretto-8-x64-linux-jdk.tar.gz
JDK8_WINDOWS_X64_URL=https://corretto.aws/downloads/latest/amazon-corretto-8-x64-windows-jdk.zip
# The manylinux2010-x86 image has a 32-bit userland only, and Corretto has no 32-bit Linux build
JDK8_LINUX_X86_URL=https://cdn.azul.com/zulu/bin/zulu8.96.0.205-ca-jdk8.0.504-linux_i686.tar.gz
BOOTLIN_AARCH64_MUSL=aarch64--musl--stable-2020.02-2
BOOTLIN_ARMV7_MUSL=armv7-eabihf--musl--stable-2020.02-2
BOOTLIN_URL=https://toolchains.bootlin.com/downloads/releases/toolchains
# musl declares cpu_set_t only under _GNU_SOURCE, which 7-Zip sets in Threads.c alone, so the musl builds
# turn CPU affinity off. The published 23.01-2.2 musl natives have no affinity symbols (glibc ones call
# sched_getaffinity), so upstream did the same.
MUSL_DEFINES=-DZ7_AFFINITY_DISABLE
# The Bootlin toolchain file sets these CFLAGS/CXXFLAGS itself; passing CMAKE_C_FLAGS replaces them,
# so they are repeated here, as its own comment instructs
BOOTLIN_DEFAULT_FLAGS="-D_LARGEFILE_SOURCE -D_LARGEFILE64_SOURCE -D_FILE_OFFSET_BITS=64 -Os"

PLATFORMS=(Mac
           Linux-amd64 Linux-i386 Linux-arm64 Linux-armv5 Linux-armv6 Linux-armv7
           Windows-amd64 Windows-x86
           Linux-amd64-musl Linux-arm64-musl Linux-armv7-musl)

step() { printf '\n==== %s\n' "$*"; }
fail() { echo "ERROR: $*" >&2; exit 1; }

# $1 url, $2 file name in $CACHE; downloads only when not cached yet
fetch() {
  if [[ -s "$CACHE/$2" ]]; then
    echo "Cached: $CACHE/$2"
  else
    curl -fL -o "$CACHE/$2.part" "$1"
    mv "$CACHE/$2.part" "$CACHE/$2"
  fi
}

# $1 platform. Succeeds when the platform zip is already built; otherwise removes a leftover
# build directory of a failed or interrupted build, so the platform is rebuilt from scratch.
already_built() {
  if [[ -f "$SRC/build-$1/sevenzipjbinding-$VERSION-$1.zip" ]]; then
    echo "Already built, skipping: $SRC/build-$1"
    return 0
  fi
  rm -rf "$SRC/build-$1"
  return 1
}

# Leftovers of an in-source cmake run (never tracked by git)
remove_in_source_leftovers() {
  (cd "$SRC" && rm -rf CMakeCache.txt CMakeFiles CPackConfig.cmake CPackSourceConfig.cmake CTestTestfile.cmake \
      DartConfiguration.tcl JUnitRunner.cmake Makefile Testing cmake_install.cmake javac-args-core.tmp \
      javac-args-test.tmp javac-test LibPropertyFileCreator.cmake MANIFEST.MF Mac _CPack_Packages \
      sevenzipjbinding-platforms.properties sevenzipjbinding-*.jar sevenzipjbinding-*.zip \
      jbinding-cpp/CMakeFiles jbinding-cpp/Makefile jbinding-cpp/cmake_install.cmake jbinding-cpp/javah \
      jbinding-cpp/lib7-Zip-JBinding.* jbinding-java/bin-core jbinding-java/bin-test \
      jbinding-java/MANIFEST.MF jbinding-java/test-MANIFEST.MF jbinding-java/sevenzipjbinding*.jar)
}

MODE="${1:-build}"
case "$MODE" in
  build | cleanup) ;;
  *) echo "Usage: $0 [build|cleanup]" >&2; exit 2 ;;
esac

[[ -n "$W" && "$W" != "/" && "$W" != "$HOME" && "$W" != "$SRC" ]] || fail "unsafe WORK_DIR: '$W'"
[[ -n "$CACHE" && "$CACHE" != "/" && "$CACHE" != "$HOME" && "$CACHE" != "$SRC" ]] || fail "unsafe CACHE_DIR: '$CACHE'"
[[ "$CACHE" != "$W" && "$CACHE" != "$W"/* ]] || fail "CACHE_DIR must be outside WORK_DIR: '$CACHE'"

if [[ "$MODE" == cleanup ]]; then
  step "Cleanup: build directories, $W and $CACHE"
  rm -rf "$SRC"/build-* "$W" "$CACHE"
  remove_in_source_leftovers
  echo "Done"
  exit 0
fi

# ---------------------------------------------------------------------------------------------
step "0/8 Preflight"
[[ "$(uname -s)" == Darwin ]] || fail "run this on macOS"
[[ -n "$VERSION" ]] || fail "cannot read SEVENZIPJBINDING_VERSON from $SRC/CMakeLists.txt"
command -v podman >/dev/null || fail "podman not found"
podman info >/dev/null 2>&1 || fail "podman machine is not running (podman machine start)"
command -v curl >/dev/null || fail "curl not found"
command -v python3 >/dev/null || fail "python3 not found"
xcrun --show-sdk-version >/dev/null || fail "Xcode command line tools not found"
MAC_JDK8="$(/usr/libexec/java_home -v 1.8)" || fail "local JDK 8 not found"
[[ -x "$MAC_JDK8/bin/javah" ]] || fail "no javah in $MAC_JDK8"
echo "Source:  $SRC"
echo "Work:    $W"
echo "Cache:   $CACHE"
echo "Version: $VERSION"

# ---------------------------------------------------------------------------------------------
step "1/8 Clean up temp files (built platforms are kept)"
rm -rf "$W"
remove_in_source_leftovers
rm -f "$CACHE"/*.part
mkdir -p "$W/dist" "$W/out" "$CACHE/apk" "$CACHE/apt-archives" "$CACHE/apt-lists"

# ---------------------------------------------------------------------------------------------
step "2/8 Download JDKs and musl toolchains (cached in $CACHE)"
fetch "$JDK8_LINUX_X64_URL" jdk8-linux-x64.tar.gz
fetch "$JDK8_LINUX_X86_URL" jdk8-linux-x86.tar.gz
fetch "$JDK8_WINDOWS_X64_URL" jdk8-windows.zip
fetch "$BOOTLIN_URL/aarch64/tarballs/$BOOTLIN_AARCH64_MUSL.tar.bz2" "$BOOTLIN_AARCH64_MUSL.tar.bz2"
fetch "$BOOTLIN_URL/armv7-eabihf/tarballs/$BOOTLIN_ARMV7_MUSL.tar.bz2" "$BOOTLIN_ARMV7_MUSL.tar.bz2"

mkdir -p "$W/jdk8-linux-x64"
tar -xzf "$CACHE/jdk8-linux-x64.tar.gz" --strip-components=1 -C "$W/jdk8-linux-x64"
[[ -f "$W/jdk8-linux-x64/bin/javah" ]] || fail "Linux JDK 8 has no javah"
mkdir -p "$W/jdk8-linux-x86"
tar -xzf "$CACHE/jdk8-linux-x86.tar.gz" --strip-components=1 -C "$W/jdk8-linux-x86"
[[ -f "$W/jdk8-linux-x86/bin/javah" ]] || fail "32-bit Linux JDK 8 has no javah"

# Only include/win32/jni_md.h is needed: Windows JNICALL differs from the Linux header
unzip -q "$CACHE/jdk8-windows.zip" '*/include/*' -d "$W/jdk8-windows-tmp"
mkdir -p "$W/jdk8-windows"
mv "$W"/jdk8-windows-tmp/*/include "$W/jdk8-windows/"
rm -rf "$W/jdk8-windows-tmp"
[[ -f "$W/jdk8-windows/include/win32/jni_md.h" ]] || fail "Windows jni_md.h not found"

# The Bootlin tarballs are extracted inside a Linux container: macOS file systems are case-insensitive

# ---------------------------------------------------------------------------------------------
step "3/8 Mac (native, universal)"
if ! already_built Mac; then
  if [[ "$("$CACHE/cmake3/bin/cmake" --version 2>/dev/null | head -1)" != "cmake version 3.28.4" ]]; then
    rm -rf "$CACHE/cmake3"
    python3 -m venv "$CACHE/cmake3"
    "$CACHE/cmake3/bin/pip" install --quiet cmake==3.28.4
  fi
  mkdir "$SRC/build-Mac"
  (
    cd "$SRC/build-Mac"
    export JAVA_HOME="$MAC_JDK8"
    "$CACHE/cmake3/bin/cmake" .. \
      -DCMAKE_POLICY_VERSION_MINIMUM=3.5 -DCMAKE_SYSTEM_NAME=Darwin -DAPPLE=TRUE -DSTATIC_BUILD=FALSE \
      -DJAVA_SYSTEM=Mac "-DJAVA_ARCH=x86_64;arm64" -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 \
      -DCMAKE_BUILD_TYPE=Release -DJAVA_JDK="$JAVA_HOME"
    make -j"$(sysctl -n hw.ncpu)"
    # Checked before "make package": the zip marks the platform as built.
    # Output is captured first: with pipefail, "grep -q" closing the pipe early can fail the producer
    slices="$(lipo -info jbinding-cpp/lib7-Zip-JBinding.dylib)"
    for arch in x86_64 arm64; do
      [[ "$slices" == *"$arch"* ]] || fail "Mac dylib has no $arch slice"
      build_version="$(otool -arch "$arch" -l jbinding-cpp/lib7-Zip-JBinding.dylib | grep -A3 LC_BUILD_VERSION)"
      [[ "$build_version" == *"minos 14.0"* ]] || fail "Mac $arch slice is not built for macOS 14.0"
    done
    if [[ "${RUN_MAC_TESTS:-0}" == 1 ]]; then
      "$CACHE/cmake3/bin/ctest" --output-on-failure
    fi
    make package
  )
fi

# ---------------------------------------------------------------------------------------------
# Runs inside every Linux container. Inputs (env): P, SYS, ARCH, EXTRA, EXPECTED_GCC, JDK, VERSION,
# optional TOOLCHAIN (default: $CMAKE_TOOLCHAIN_FILE set by dockcross images), CHECK_CC and
# C_CXX_FLAGS (passed as both CMAKE_C_FLAGS and CMAKE_CXX_FLAGS).
CONTAINER_BUILD='
set -eux
TOOLCHAIN=${TOOLCHAIN:-${CMAKE_TOOLCHAIN_FILE:-}}
cc_bin=${CHECK_CC:-${CC:-$(command -v "${CROSS_TRIPLE:-none}-gcc" || command -v gcc)}}
"$cc_bin" --version | head -1 > /tmp/cc-version
cat /tmp/cc-version
grep -qF "$EXPECTED_GCC" /tmp/cc-version || { echo "Unexpected compiler, expected GCC $EXPECTED_GCC" >&2; exit 1; }
cmake --version 2>&1 | grep "cmake version" || true  # the MXE wrapper prints its own lines first
mkdir "/work/build-$P" && cd "/work/build-$P"
cmake .. ${TOOLCHAIN:+-DCMAKE_TOOLCHAIN_FILE=$TOOLCHAIN} -DCMAKE_BUILD_TYPE=Release \
  -DJAVA_JDK="$JDK" -DJAVA_SYSTEM="$SYS" -DJAVA_ARCH="$ARCH" $EXTRA \
  ${C_CXX_FLAGS:+"-DCMAKE_C_FLAGS=$C_CXX_FLAGS" "-DCMAKE_CXX_FLAGS=$C_CXX_FLAGS"}
make -j"$(nproc)"
make package
test -f "sevenzipjbinding-$VERSION-$P.zip"
'

# $1 platform, $2 dockcross image with tag, $3 JAVA_SYSTEM, $4 JAVA_ARCH, $5 expected GCC version, $6 extra cmake flags,
# $7 JDK 8 directory to mount (default: the 64-bit one)
build_dockcross() {
  step "4/8 $1 (docker.io/dockcross/$2)"
  already_built "$1" && return 0
  podman run --rm --platform linux/amd64 \
    -v "$SRC":/work -v "${7:-$W/jdk8-linux-x64}":/jdk8:ro -v "$W/jdk8-windows":/jdkwin:ro \
    -e P="$1" -e SYS="$3" -e ARCH="$4" -e EXPECTED_GCC="$5" -e EXTRA="${6:-}" -e JDK=/jdk8 -e VERSION="$VERSION" \
    "docker.io/dockcross/$2" bash -c "$CONTAINER_BUILD"
}

build_dockcross Linux-amd64   manylinux2010-x64:$DOCKCROSS_TAG          Linux   amd64 8.3.1
build_dockcross Linux-i386    manylinux2010-x86:$DOCKCROSS_TAG          Linux   i386  8.3.1 "" "$W/jdk8-linux-x86"
build_dockcross Linux-arm64   linux-arm64:$DOCKCROSS_TAG                Linux   arm64 8.3.0
build_dockcross Linux-armv5   linux-armv5:$DOCKCROSS_TAG                Linux   armv5 4.9.4
build_dockcross Linux-armv6   linux-armv6:$DOCKCROSS_TAG                Linux   armv6 4.8.3
build_dockcross Linux-armv7   linux-armv7a:$DOCKCROSS_TAG               Linux   armv7 6.3.1
build_dockcross Windows-amd64 windows-static-x64:$DOCKCROSS_WINDOWS_TAG Windows amd64 9.2.0 "-DMINGW64=Yes -DJAVA_INCLUDE_PATH2=/jdkwin/include/win32"
build_dockcross Windows-x86   windows-static-x86:$DOCKCROSS_WINDOWS_TAG Windows x86   9.2.0 "-DMINGW32=Yes -DJAVA_INCLUDE_PATH2=/jdkwin/include/win32"

# ---------------------------------------------------------------------------------------------
step "5/8 Linux-amd64-musl (alpine:3.12)"
if ! already_built Linux-amd64-musl; then
  # /etc/apk/cache is apk's package cache when the directory exists
  podman run --rm --platform linux/amd64 -v "$SRC":/work -v "$CACHE/apk":/etc/apk/cache \
    -e P=Linux-amd64-musl -e SYS=Linux -e ARCH=amd64-musl -e EXPECTED_GCC=9.3.0 -e EXTRA= \
    -e C_CXX_FLAGS="$MUSL_DEFINES" \
    -e JDK=/usr/lib/jvm/java-1.8-openjdk -e VERSION="$VERSION" \
    docker.io/library/alpine:3.12 sh -c "apk update && apk add build-base cmake openjdk8 bash && bash -c '$CONTAINER_BUILD'"
fi

# Debian containers keep downloaded .deb files and package lists in $CACHE;
# docker-clean is the image's hook that would delete the .deb files after each install
APT_CACHE_MOUNTS=(-v "$CACHE/apt-archives":/var/cache/apt/archives -v "$CACHE/apt-lists":/var/lib/apt/lists)
APT_KEEP_DEBS='rm -f /etc/apt/apt.conf.d/docker-clean'

# ---------------------------------------------------------------------------------------------
# $1 platform, $2 JAVA_ARCH, $3 Bootlin toolchain name
build_bootlin() {
  step "6/8 $1 (Bootlin $3)"
  already_built "$1" && return 0
  podman run --rm --platform linux/amd64 -v "$SRC":/work -v "$W":/cross:ro -v "$CACHE":/cache:ro \
    "${APT_CACHE_MOUNTS[@]}" \
    -e P="$1" -e SYS=Linux -e ARCH="$2" -e EXPECTED_GCC=8.4.0 -e EXTRA= -e JDK=/cross/jdk8-linux-x64 \
    -e VERSION="$VERSION" -e TC="$3" -e C_CXX_FLAGS="$BOOTLIN_DEFAULT_FLAGS $MUSL_DEFINES" \
    docker.io/library/debian:bookworm bash -c "$APT_KEEP_DEBS"'
      set -eux
      apt-get update
      apt-get install -y --no-install-recommends cmake make bzip2
      tar -xjf "/cache/$TC.tar.bz2" -C /opt
      export TOOLCHAIN="/opt/$TC/share/buildroot/toolchainfile.cmake"
      test -f "$TOOLCHAIN"
      set -- /opt/"$TC"/bin/*-gcc
      export CHECK_CC="$1"
      bash -c "$0"' "$CONTAINER_BUILD"
}

build_bootlin Linux-arm64-musl arm64-musl "$BOOTLIN_AARCH64_MUSL"
build_bootlin Linux-armv7-musl armv7-musl "$BOOTLIN_ARMV7_MUSL"

# ---------------------------------------------------------------------------------------------
step "7/8 Merge into AllPlatforms"
for p in "${PLATFORMS[@]}"; do
  zip="$SRC/build-$p/sevenzipjbinding-$VERSION-$p.zip"
  [[ -f "$zip" ]] || fail "missing $zip"
  cp "$zip" "$W/dist/"
done
podman run --rm --platform linux/amd64 -v "$SRC":/src:ro -v "$W":/w "${APT_CACHE_MOUNTS[@]}" -e VERSION="$VERSION" \
  docker.io/library/debian:bookworm bash -c "$APT_KEEP_DEBS"'
    set -eux
    apt-get update
    apt-get install -y --no-install-recommends zip unzip
    export PATH=/w/jdk8-linux-x64/bin:$PATH
    cd /w/dist
    bash /src/scripts/build-multiplatform-release.sh sevenzipjbinding-$VERSION-*.zip'
RESULT="$W/out/sevenzipjbinding-all-platforms-$VERSION.jar"
unzip -p "$W/dist/sevenzipjbinding-$VERSION-AllPlatforms.zip" \
  "sevenzipjbinding-$VERSION-AllPlatforms/lib/sevenzipjbinding-AllPlatforms.jar" > "$RESULT"

# ---------------------------------------------------------------------------------------------
step "8/8 Verify result"
mkdir "$W/verify"
unzip -q "$RESULT" -d "$W/verify"
[[ "$(grep -c '^platform\.' "$W/verify/sevenzipjbinding-platforms.properties")" == "${#PLATFORMS[@]}" ]] \
  || fail "sevenzipjbinding-platforms.properties does not list ${#PLATFORMS[@]} platforms"
for p in "${PLATFORMS[@]}"; do
  libs=("$W/verify/$p"/lib7-Zip-JBinding.*)
  [[ ${#libs[@]} == 1 ]] || fail "no native library for $p"
  compiler="$(strings -a "${libs[0]}" | grep -E '^GCC: \(' | sort -u | tr '\n' ' ' || true)"
  printf '%-18s %s\n' "$p" "${compiler:-(clang)}"
done
rm -rf "$W/verify"

echo
echo "Result: $RESULT"
echo "Built platforms are kept in $SRC/build-*; run \"$0 cleanup\" to remove everything"
