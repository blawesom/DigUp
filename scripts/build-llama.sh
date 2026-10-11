#!/bin/bash
# Builds llama.cpp (MIT), the embedding runtime: the pinned build tag plus scripts/llama.cpp-no-logits.patch, as static
# libraries into Vendor/llama/lib and the headers into Vendor/llama/include (all out of git).
# - macOS: Metal, the shaders embedded and compiled on first use (no Metal toolchain needed), one static archive
#   merged with libtool.
# - Linux: CPU, plus Vulkan when the shader compiler is there (one backend covering Intel, AMD and NVIDIA
#   small GPUs); the Vulkan headers are fetched into Vendor when the system has none, the loader stays the
#   system's. Native instructions: it runs where it's built.
# CMake comes from PATH, or from a venv in Vendor/ (needs uv). Does nothing when that build is already there;
# build.sh runs it every time.
set -euo pipefail
cd "$(dirname "$0")/.."
TAG=b11461   # the first tags with EmbeddingGemma 2 (text + vision + audio) are b11452+
# A new TAG ships only if `swift test` passes: ReferenceVectorTests checks it makes the same vectors, so every index is
# kept. If it fails, keep this TAG, or bump LlamaEmbedder.vectorVersion and write the reference vectors again
# (DIGUP_WRITE_REFERENCE=1 swift test --filter ReferenceVectorTests): every index then embeds again.
PATCH=scripts/llama.cpp-no-logits.patch
SOURCE=Vendor/llama.cpp
OUT=Vendor/llama

SYSTEM=$(uname -s)
if [[ "$SYSTEM" == "Darwin" ]]; then
  BACKEND="metal"
else
  # Vulkan needs the shader compiler; CI's runners have none and stay on the CPU.
  if command -v glslc > /dev/null; then BACKEND="vulkan"; else BACKEND="cpu"; fi
fi
STAMP="$TAG $SYSTEM $BACKEND $(shasum -a 256 "$PATCH" | cut -c1-12)"
BUILT="$OUT/lib/libggml-cpu.a"; [[ "$SYSTEM" == "Darwin" ]] && BUILT="$OUT/lib/libllamacpp.a"
if [[ -f "$BUILT" && "$(cat "$OUT/BUILD" 2>/dev/null)" == "$STAMP" ]]; then
  exit 0
fi
if [[ "$SYSTEM" == "Darwin" && -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

if [[ ! -d "$SOURCE" ]]; then
  git -c advice.detachedHead=false clone --quiet --depth 1 --branch "$TAG" https://github.com/ggml-org/llama.cpp "$SOURCE"
elif [[ "$(git -C "$SOURCE" describe --tags --exact-match 2>/dev/null)" != "$TAG" ]]; then
  git -C "$SOURCE" fetch --quiet --depth 1 origin tag "$TAG"
  git -C "$SOURCE" checkout --quiet --force "$TAG"   # --force also drops the old patch
fi
# Without the patch, every input token costs 1 MiB of logits that an embedding model never produces (262k vocabulary).
if git -C "$SOURCE" apply --check "../../$PATCH" 2>/dev/null; then
  git -C "$SOURCE" apply "../../$PATCH"
fi

if ! command -v cmake > /dev/null; then
  if [[ ! -x Vendor/cmake-venv/bin/cmake ]]; then
    uv venv --quiet Vendor/cmake-venv --python 3.12
    uv pip install --quiet --python Vendor/cmake-venv/bin/python cmake ninja
  fi
  export PATH="$PWD/Vendor/cmake-venv/bin:$PATH"
fi
GENERATOR=$(command -v ninja > /dev/null && echo Ninja || echo "Unix Makefiles")

EXTRA=()
if [[ "$SYSTEM" == "Darwin" ]]; then
  # Only the libraries: no tools, no server, nothing downloaded at build time. The Metal shaders are embedded and
  # compiled on first use, so no Metal toolchain is needed.
  EXTRA=(-DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 -DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON -DGGML_NATIVE=OFF)
else
  # Position independent: the test bundles link it into shared libraries.
  EXTRA=(-DCMAKE_POSITION_INDEPENDENT_CODE=ON -DGGML_METAL=OFF -DGGML_CUDA=OFF -DGGML_NATIVE=ON)
  if [[ "$BACKEND" == "vulkan" ]]; then
    # The headers cmake looks for, fetched when the system has none (the loader and the ICD stay the system's);
    # pinned to the loader's version so they agree.
    VULKAN_HEADERS=Vendor/vulkan-headers
    LOADER_VERSION=$(basename "$(ls /usr/lib/libvulkan.so.1.* 2>/dev/null | tail -1)" | sed 's/^libvulkan\.so\.//')
    VERSION=${LOADER_VERSION:-1.4.363}
    if [[ ! -f /usr/include/vulkan/vulkan.h && ! -f "$VULKAN_HEADERS/include/vulkan/vulkan_core.h" ]]; then
      echo "fetching Vulkan headers $VERSION (the system has none)…"
      curl -sL "https://github.com/KhronosGroup/Vulkan-Headers/archive/refs/tags/v$VERSION.tar.gz" | tar xz -C Vendor
      mv "Vendor/Vulkan-Headers-$VERSION" "$VULKAN_HEADERS"
    fi
    if [[ -d "$VULKAN_HEADERS/include" ]]; then
      EXTRA+=(-DCMAKE_INCLUDE_PATH="$PWD/$VULKAN_HEADERS/include")
    fi
    # llama.cpp's Vulkan wants SPIRV-Headers as a cmake package, which the system may not have either; it's
    # fetched and installed alongside, versioned with the Vulkan headers.
    if [[ ! -f Vendor/spirv-headers-install/share/cmake/SPIRV-Headers/SPIRV-HeadersConfig.cmake
          && ! -f /usr/share/cmake/SPIRV-Headers/SPIRV-HeadersConfig.cmake
          && ! -f /usr/lib/cmake/SPIRV-Headers/SPIRV-HeadersConfig.cmake ]]; then
      rm -rf Vendor/SPIRV-Headers-* Vendor/spirv-headers Vendor/spirv-headers-build
      echo "fetching SPIRV headers (the system has none)…"
      curl -sL "https://github.com/KhronosGroup/SPIRV-Headers/archive/refs/tags/vulkan-sdk-$VERSION.0.tar.gz" | tar xz -C Vendor
      mv "Vendor/SPIRV-Headers-vulkan-sdk-$VERSION.0" Vendor/spirv-headers
      cmake -S Vendor/spirv-headers -B Vendor/spirv-headers-build -DCMAKE_INSTALL_PREFIX="$PWD/Vendor/spirv-headers-install" > /dev/null
      cmake --install Vendor/spirv-headers-build > /dev/null
    fi
    # llama.cpp finds the SPIRV-Headers package but puts nothing on the compile path itself (on a distro they
    # live in /usr/include); ours goes in through the compiler flags.
    if [[ -d Vendor/spirv-headers-install/include && ! -f /usr/include/spirv/unified1/spirv.hpp ]]; then
      EXTRA+=(-DCMAKE_CXX_FLAGS="-isystem $PWD/Vendor/spirv-headers-install/include")
    fi
    EXTRA+=(-DCMAKE_PREFIX_PATH="$PWD/Vendor/spirv-headers-install")
    EXTRA+=(-DGGML_VULKAN=ON)
  else
    EXTRA+=(-DGGML_VULKAN=OFF)
  fi
fi

cmake -S "$SOURCE" -B Vendor/llama-build -G "$GENERATOR" -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF \
  -DLLAMA_BUILD_MTMD=ON -DLLAMA_BUILD_COMMON=OFF -DLLAMA_BUILD_TOOLS=OFF -DLLAMA_BUILD_SERVER=OFF \
  -DLLAMA_BUILD_EXAMPLES=OFF -DLLAMA_BUILD_TESTS=OFF -DLLAMA_BUILD_APP=OFF -DLLAMA_BUILD_UI=OFF \
  -DLLAMA_OPENSSL=OFF "${EXTRA[@]}" > /dev/null
cmake --build Vendor/llama-build --config Release -j "$(nproc 2>/dev/null || sysctl -n hw.ncpu)" \
  --target llama mtmd > /dev/null

B=Vendor/llama-build
mkdir -p "$OUT/lib" "$OUT/include"
if [[ "$SYSTEM" == "Darwin" ]]; then
  xcrun libtool -static -no_warning_for_no_symbols -o "$OUT/lib/libllamacpp.a" \
    $B/src/libllama.a $B/tools/mtmd/libmtmd.a $B/ggml/src/libggml.a $B/ggml/src/libggml-base.a \
    $B/ggml/src/libggml-cpu.a $B/ggml/src/ggml-metal/libggml-metal.a $B/ggml/src/ggml-blas/libggml-blas.a \
    $B/vendor/hash/libvendor-hash.a
else
  # The CPU library holds two members of one name (repack.cpp.o from two folders), which no archive merge keeps;
  # the linker reads them both, so the libraries are kept as they are.
  cp $B/src/libllama.a $B/tools/mtmd/libmtmd.a $B/ggml/src/libggml.a $B/ggml/src/libggml-base.a \
     $B/ggml/src/libggml-cpu.a $B/vendor/hash/libvendor-hash.a "$OUT/lib/"
  if [[ -f $B/ggml/src/ggml-vulkan/libggml-vulkan.a ]]; then
    cp $B/ggml/src/ggml-vulkan/libggml-vulkan.a "$OUT/lib/"
    rm -f "$OUT/lib/libvulkan.a"   # the system's loader is the one to link
  else
    # A CPU-only build: empty archives keep the link line the same either way (an empty archive satisfies
    # -lggml-vulkan, and -lvulkan when the system has no loader — nothing references Vulkan's symbols).
    ar rcs "$OUT/lib/libggml-vulkan.a"
    ar rcs "$OUT/lib/libvulkan.a"
  fi
fi
cp "$SOURCE/include/llama.h" "$SOURCE"/ggml/include/*.h "$SOURCE/tools/mtmd/mtmd.h" "$SOURCE/tools/mtmd/mtmd-helper.h" \
  "$OUT/include/"
# The build, for logs and `digup status` (indexes record LlamaEmbedder.vectorVersion, not this). SwiftPM doesn't see a
# changed header, so the Swift file that reads it is touched.
printf '// Written by scripts/build-llama.sh.\n#define LLAMA_BUILD_TAG "%s"\n' "$TAG" > "$OUT/include/llama-build.h"
touch Sources/LlamaRuntime/LlamaEmbedder.swift
echo "$STAMP" > "$OUT/BUILD"
echo "Built llama.cpp $TAG (patched, $SYSTEM $BACKEND) into $OUT"
