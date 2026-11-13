#!/bin/sh
# Builds llama.cpp for the llama worker, from the source pinned in
# reference/sources.json (fetch it with `uv run scripts/fetch_sources.py`).
#
# The upstream way: llama.cpp's own CMake build with the settings its
# build-xcframework.sh uses for macOS, here for arm64 only, as static
# libraries with Metal and the Metal shaders built in. Two departures, both
# for the worker: common/ is built, for the chat template machinery
# (common/chat), and there is no BLAS and no multimodal library. llama.cpp's
# server, tools, examples, HTTPS, subprocess and grammar-library code are not
# built. The libraries are joined into one archive, .llama/lib/libllamacpp.a,
# which leaves out common's HTTP client library (cpp-httplib) so the worker
# cannot link any of it. Two build jobs at low priority; CMake comes from
# PyPI through uv, at one exact version.
set -eu
cd "$(dirname "$0")"
cmake="uv tool run --from cmake==4.4.4 cmake"
nice -n 10 $cmake -S ../reference/src/llama.cpp -B .llama/build \
	-DCMAKE_BUILD_TYPE=Release \
	-DCMAKE_OSX_ARCHITECTURES=arm64 \
	-DCMAKE_OSX_DEPLOYMENT_TARGET=15.0 \
	-DBUILD_SHARED_LIBS=OFF \
	-DLLAMA_BUILD_COMMON=ON \
	-DLLAMA_BUILD_APP=OFF \
	-DLLAMA_BUILD_EXAMPLES=OFF \
	-DLLAMA_BUILD_TOOLS=OFF \
	-DLLAMA_BUILD_TESTS=OFF \
	-DLLAMA_BUILD_SERVER=OFF \
	-DLLAMA_BUILD_MTMD=OFF \
	-DLLAMA_OPENSSL=OFF \
	-DLLAMA_SUBPROCESS=OFF \
	-DLLAMA_LLGUIDANCE=OFF \
	-DGGML_METAL=ON \
	-DGGML_METAL_EMBED_LIBRARY=ON \
	-DGGML_BLAS=OFF \
	-DGGML_OPENMP=OFF \
	-DGGML_NATIVE=OFF
nice -n 10 $cmake --build .llama/build --config Release --target llama-common -j 2
mkdir -p .llama/lib
libtool -static -no_warning_for_no_symbols -o .llama/lib/libllamacpp.a \
	.llama/build/common/libllama-common.a \
	.llama/build/common/libllama-common-base.a \
	.llama/build/src/libllama.a \
	.llama/build/ggml/src/libggml.a \
	.llama/build/ggml/src/libggml-base.a \
	.llama/build/ggml/src/libggml-cpu.a \
	.llama/build/ggml/src/ggml-metal/libggml-metal.a
echo "$(pwd)/.llama/lib/libllamacpp.a"
