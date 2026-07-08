#!/usr/bin/env bash

exit 0

set -ex

zig fmt build.zig src --check
zig build
./zig-out/bin/sphsvg_test
