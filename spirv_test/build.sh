#!/usr/bin/env bash

set -ex
#LD_LIBRARY_PATH=/nix/store/chqq8mpmpyfi9kgsngya71akv5xicn03-gcc-15.2.0-lib/lib/ ~/work/zig/zig-out/bin/zig build-exe -Dllvm -target spirv32-opengl -mcpu generic,+float64 shader.zig
LD_LIBRARY_PATH=/nix/store/chqq8mpmpyfi9kgsngya71akv5xicn03-gcc-15.2.0-lib/lib/ ~/work/zig/zig-out/bin/zig build --zig-lib=/home/streamer/work/zig/lib --verbose

#LD_LIBRARY_PATH=/nix/store/chqq8mpmpyfi9kgsngya71akv5xicn03-gcc-15.2.0-lib/lib/ /home/streamer/work/zig/zig-out/bin/zig build-exe -ODebug -target spirv32-opengl-none -mcpu baseline+float64+v1_6+variable_pointers --dep sphtud -Mroot=shader.zig -Msphtud=sphtud/sphtud.zig --build-root . --name shader --zig-lib-dir /home/streamer/work/zig/lib/

spirv-val  ./zig-out/bin/pass1.spv
spirv-val  ./zig-out/bin/pass2.spv
