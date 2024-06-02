#!/bin/bash
cd $1
cd device/common/br_overlay/lib
ln -s /usr/lib64/lp64d/libc.so ld-musl-riscv64.so.1
