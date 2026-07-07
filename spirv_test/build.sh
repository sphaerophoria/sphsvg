#!/usr/bin/env bash

LD_LIBRARY_PATH=/nix/store/chqq8mpmpyfi9kgsngya71akv5xicn03-gcc-15.2.0-lib/lib/ ~/work/zig/zig-out/bin/zig build-exe -Dllvm -target spirv32-opengl shader.zig
