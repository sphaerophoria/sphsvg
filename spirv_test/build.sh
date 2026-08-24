#!/usr/bin/env bash

set -ex
#LD_LIBRARY_PATH=/nix/store/chqq8mpmpyfi9kgsngya71akv5xicn03-gcc-15.2.0-lib/lib/ ~/work/zig/zig-out/bin/zig build-exe -Dllvm -target spirv32-opengl -mcpu generic,+float64 shader.zig
LD_LIBRARY_PATH=/nix/store/chqq8mpmpyfi9kgsngya71akv5xicn03-gcc-15.2.0-lib/lib/ ~/work/zig/zig-out/bin/zig build --zig-lib=/home/streamer/work/zig/lib --verbose

spirv-val  ./zig-out/bin/shader.spv
