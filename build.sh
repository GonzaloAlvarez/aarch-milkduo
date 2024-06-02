#!/bin/bash

##
# Main build script to build milkv duo buildroot from xuantie toolchain and sdk
#
# References:
#
# - Hi, I managed to get a native compiler up and running for riscv64 by using the following procedure: https://github.com/riscv-collab/riscv-gnu-toolchain/issues/1427
# - Yolo ML model on C906 - https://community.milkv.io/t/tdl-sdk-yolov5/1639
# - Musl duo compilaton targets for packages: https://github.com/milkv-duo/duo-buildroot-sdk/issues/18
# - Multilib clue for musl compilation - https://gcc.gnu.org/bugzilla/show_bug.cgi?id=90419
# - C906 T-Head Spec: https://occ-oss-prod.oss-cn-hangzhou.aliyuncs.com/resource//1659515330848/%E7%8E%84%E9%93%81CPU%E8%BD%AF%E4%BB%B6%E5%BC%80%E5%8F%91%E6%8C%87%E5%8D%97V2.2.pdf
# - FW Payload OpenEuler Sources: https://gitee.com/openeuler
# - Multilib generation codes: https://github.com/orangecms/xuantie-gnu-toolchain/blob/3c9ed63d71ace863125b82dab63759a697e6b9ba/configure#L3376
# - Multilib for alpine: https://github.com/alpinelinux/aports/blob/80d83eb0313a31cd84ea528f82d7bc9e2cdf6c89/community/g%2B%2B-cross-embedded/APKBUILD#L52
# - SiFive explanation for multilib: https://www.sifive.com/blog/all-aboard-part-5-risc-v-multilib
# - OpenEuler repo: https://repo.openeuler.org/openEuler-preview/RISC-V/openEuler-22.09-riscv64/QEMU/
# - Building OpenEuler QEmu: https://www.cnblogs.com/lifeislife/p/17589761.html
# - Building HiFive image and QEmu: https://blog.csdn.net/wangyijieonline/article/details/104693293
# - Xuantie QEmu version: https://zhuanlan-zhihu-com.translate.goog/p/659117537?_x_tr_sl=auto&_x_tr_tl=en&_x_tr_hl=en&_x_tr_pto=wapp
##

set -eu
set -x
set -o pipefail
set -o errtrace
trap '_fail "command error"' ERR

_info() {
    echo -e "\033[1;32m$1\033[0m"
}

_fail() {
    local msg="$1"
    echo -e "[\033[1;33mFATAL\033[0m]: $msg">&2

    local i=0 info
    while info=$(caller $i); do
        set -- $info
        local line=$1 func=$2 file=$3
        printf '\t%s at %s:%s\n' "$func" "$file" "$line" >&2
        (( i += 1 ))
    done

    kill -ABRT -$$
}

ROOT_PATH="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
OUTPUT_PATH="$ROOT_PATH/output"
HOSTTOOLS_PATH="$ROOT_PATH/host-tools"
BUILDTOOLS_PATH="$ROOT_PATH/build-tools"

APT_DEPENDENCIES="pkg-config build-essential ninja-build automake autoconf libtool wget curl git gcc libssl-dev bc slib squashfs-tools android-sdk-libsparse-utils jq python3-distutils scons parallel tree python3-dev python3-pip device-tree-compiler ssh cpio fakeroot libncurses5 flex bison libncurses5-dev genext2fs rsync unzip dosfstools mtools tcl openssh-client cmake expect"

i_buildroot_dependencies() {
    _info "Installing buildroot dependencies..."
    set +eu
    for package in $(echo $APT_DEPENDENCIES); do
        is_missing=$(dpkg --get-selections $package | grep -v ' install$' | awk '{print $6} ')
        [[ ! -z "$is_missing" ]] && sudo apt-get install $package
    done
    set -eu
}

_cache_path="$ROOT_PATH/pkgcache"

cached_clone() {
    # if in cache, use that
    _repo="$1"
    _name="$2"
    _tag="$3"
    _branch=""
    [[ ! -z "$_tag" ]] && _branch="-b $_tag --single-branch"

    if [ -d "$OUTPUT_PATH/$_name" ] && [ -z "$(ls -A "$OUTPUT_PATH/$_name")" ]; then
        _fail "Failing ungracefully. $_name already exists in output"
    fi

    if [ -f "$_cache_path/${_name}-${_tag}.tbz" ]; then
        _info "Package [$_name] is cached. Using cached version"
        mkdir -p $OUTPUT_PATH
        tar -xjf "$_cache_path/${_name}-${_tag}.tbz" -C $OUTPUT_PATH
    else
        _info "Package [$_name] is no cached. Retrieving"
        pushd "$(pwd)" &>/dev/null

        git clone $_branch --depth 1 $_repo "$OUTPUT_PATH/$_name" 2>/dev/null
        cd "$OUTPUT_PATH/$_name"
        git submodule init
        git submodule update
        cd ..
        _info "Caching package [$_name]"
        mkdir -p $_cache_path
        tar -cjf $_cache_path/${_name}-${_tag}.tbz $_name

        popd
    fi
}

_xuantie_tc="xuantie-gnu-toolchain"
_xuantie_tc_path="$OUTPUT_PATH/$_xuantie_tc"
_musl_tc="musl"
_musl_tc_path="$OUTPUT_PATH/$_musl_tc"

install_toolchain_base() {
    _info "Building the Xuantie GNU Toolchain from scratch"
    cached_clone https://github.com/T-head-Semi/xuantie-gnu-toolchain $_xuantie_tc "V2.8.1"
    cd $_xuantie_tc_path
    sed -i 's/^\#include \"\.\.\/\.\.\/libgloss\/libnosys\/config\.h\"$/\/\/removed libgloss libnosys config dependency/' riscv-newlib/newlib/libc/machine/riscv/pthread.c
    cached_clone https://git.musl-libc.org/git/musl $_musl_tc "v1.2.5"
}

# host-tools/gcc/riscv64-elf-arm64/bin/riscv64-unknown-elf-gcc
# host-tools/gcc/riscv64-linux-arm64/bin/riscv64-unknown-linux-gnu-gcc
# host-tools/gcc/riscv64-linux-musl-arm64/bin/riscv64-unknown-linux-musl-gcc
platform="arm64"
_tc_elf_path="$HOSTTOOLS_PATH/gcc/riscv64-elf-$platform"
_tc_elf_gcc="$_tc_elf_path/bin/riscv64-unknown-elf-gcc"
_tc_lnx_path="$HOSTTOOLS_PATH/gcc/riscv64-linux-$platform"
_tc_lnx_gcc="$_tc_lnx_path/bin/riscv64-unknown-linux-gnu-gcc"
_tc_musl_path="$HOSTTOOLS_PATH/gcc/riscv64-linux-musl-$platform"
_tc_musl_gcc="$_tc_musl_path/bin/riscv64-unknown-linux-musl-gcc"

clean_xuantie() {
    pushd "$(pwd)" &>/dev/null

    cd $_xuantie_tc_path
    _info "Cleaning Xuantie libraries"
    make clean || true
    make distclean || true
    for i in */; do cd $i; make clean || true; make distclean || true; cd ..;done

    popd
}

install_toolchain() {
    if [ ! -x $_tc_elf_gcc ] && [ ! -x $_tc_lnx_gcc ] && [ ! -x $_tc_musl_gcc ]; then
        _info "Missing at least one of the toolchain gcc execs. Need to bring the library"
        install_toolchain_base
    fi

    local _extra_args="--with-arch=rv64imafd --with-abi=lp64d --with-system-zlib --enable-tls --with-newlib --enable-multilib --disable-shared"

    if [ ! -x $_tc_elf_gcc ]; then
        rm -Rf "$_tc_elf_path"
        mkdir -p "$_tc_elf_path"
        clean_xuantie
        cd $_xuantie_tc_path
        _info "Building Xuantie ELF libraries"
        ./configure --with-cmodel=medany --prefix=$_tc_elf_path $_extra_args
        make -j $(nproc)
    fi
    if [ ! -x $_tc_lnx_gcc ]; then
        rm -Rf "$_tc_lnx_path"
        mkdir -p "$_tc_lnx_path"
        clean_xuantie
        cd $_xuantie_tc_path
        _info "Building Xuantie Linux libraries"
        ./configure --with-cmodel=medany --prefix=$_tc_lnx_path $_extra_args
        make linux -j $(nproc)
    fi
    if [ ! -x $_tc_musl_gcc ]; then
        rm -Rf "$_tc_musl_path"
        mkdir -p "$_tc_musl_path"
        clean_xuantie
        cd $_xuantie_tc_path
        _info "Building Xuantie Musl libraries"
        ./configure --with-musl-src=$_musl_tc_path --with-cmodel=medany --prefix=$_tc_musl_path $_extra_args
        make musl -j $(nproc)
    fi
    [[ -d "$_xuantie_tc_path" ]] && RM -Rf "$_xuantie_tc_path"
}

_duobuildroot_sdk="duo-buildroot-sdk"
_dbr_path="$OUTPUT_PATH/$_duobuildroot_sdk"

_build_gen_init_cpio() {
    rm -f "$_dbr_path/build/tools/common/gen_init_cpio"
    gcc "$_dbr_path/linux_5.10/usr/gen_init_cpio.c" -o "$_dbr_path/build/tools/common/gen_init_cpio"
}

_build_uboot_mkimage() {
    pushd "$(pwd)" &>/dev/null

    local uboot_name="u-boot-2021.10"
    local uboot_path="$OUTPUT_PATH/$uboot_name"
    cached_clone https://github.com/u-boot/u-boot $uboot_name "v2021.10"
    cd "$uboot_path"
    make defconfig
    make tools
    cp -f "$uboot_path/tools/mkimage" "$_dbr_path/build/tools/common/prebuild"

    popd
}

target_duo256() {
    install_toolchain
    i_buildroot_dependencies
    mkdir -p "$OUTPUT_PATH"
    cached_clone https://github.com/milkv-duo/duo-buildroot-sdk.git $_duobuildroot_sdk "Duo-V1.1.0"

    # copy toolchain and tools
    cp -R $HOSTTOOLS_PATH "$_dbr_path"
    _build_gen_init_cpio
    _build_uboot_mkimage

    # fix paths
    sed -in 's/CROSS_COMPILE_PATH_64_NONOS_RISCV64=.*$/CROSS_COMPILE_PATH_64_NONOS_RISCV64="\$TOOLCHAIN_PATH"\/gcc\/riscv64-elf-arm64/' $_dbr_path/build/milkvsetup.sh
    sed -in 's/CROSS_COMPILE_PATH_GLIBC_RISCV64=.*$/CROSS_COMPILE_PATH_GLIBC_RISCV64="\$TOOLCHAIN_PATH"\/gcc\/riscv64-linux-arm64/' $_dbr_path/build/milkvsetup.sh
    sed -in 's/CROSS_COMPILE_PATH_MUSL_RISCV64=.*$/CROSS_COMPILE_PATH_MUSL_RISCV64="\$TOOLCHAIN_PATH"\/gcc\/riscv64-linux-musl-arm64/' $_dbr_path/build/milkvsetup.sh

    # do patches
    for p_script in patches/*.sh; do
        $p_script $_dbr_path
    done

    # do diffs
    for p_diff in patches/*.diff; do
        pushd "$(pwd)" &>/dev/null
        cd "$_dbr_path"
        git apply "$ROOT_PATH/$p_diff"
        popd
    done
    cd $_dbr_path
    #build
    ./build.sh milkv-duo256m
}

target_clean() {
    rm -Rf $OUTPUT_PATH
}

target_distclean() {
    target_clean
    rm -Rf $HOSTTOOLS_PATH
}

cache_curl() {
    # if in cache, use that
    _url="$1"
    _name="$2"

    if [ -f "$_cache_path/${_name}" ]; then
        _info "File [$_name] is cached. Using cached version"
        mkdir -p $OUTPUT_PATH
        cp "$_cache_path/${_name}" $OUTPUT_PATH/
    else
        _info "File [$_name] is no cached. Retrieving"
        pushd "$(pwd)" &>/dev/null
        curl -L -o "$OUTPUT_PATH/$_name" "$_url"
        popd
    fi
}

_qemu="qemu"
_qemu_src_path="$OUTPUT_PATH/$_qemu"
_qemu_bin_path="$HOSTTOOLS_PATH/$_qemu"
_qemu_binary="$_qemu_bin_path/bin/qemu-system-riscv64"
_fw_url="https://de-repo.openeuler.org/openEuler-preview/RISC-V/openEuler-22.03-V1-riscv64/QEMU/fw_payload_oe_qemuvirt.elf"
_q_fw_jump_name="fw_payload.elf"
_q_fw_jump="$OUTPUT_PATH/$_q_fw_jump_name"
#_q_fw_jump="$_dbr_path/install/soc_cv1812cp_milkv_duo256m_sd/elf/fw_payload_uboot.elf"
install_qemu() {
    if [ ! -x "$_qemu_binary" ]; then
        cached_clone https://gitlab.com/qemu-project/qemu qemu "stable-8.1"
        cd $_qemu_src_path
        _info "Building qemu"
        ./configure --prefix="$_qemu_bin_path" --target-list=aarch64-softmmu,arm-softmmu,riscv32-softmmu,riscv64-softmmu
        make
        make install
    fi
}

install_firmware() {
    if [ ! -f "$_q_fw_jump" ]; then
        _info "Retrieving the fw_payload"
        cache_curl "$_fw_url" "$_q_fw_jump_name"
    fi
}

_q_cpu="-M virt"
_q_kernel="-kernel $_q_fw_jump -bios none"
_q_main_opts="-nographic -m 1G -smp 8"
_q_net="-netdev user,id=net0,hostfwd=tcp::2222-:22 -device virtio-net-device,netdev=net0"
_q_devs="-device qemu-xhci -usb -device usb-kbd -device usb-tablet"
_q_append="root=/dev/vda2 rw console=ttyS0 swiotlb=1 loglevel=3 systemd.default_timeout_start_sec=600 selinux=0 highres=off mem=512M earlycon"
# host-tools/qemu/bin/qemu-system-riscv64 -M virt -bios output/fw_payload.elf -kernel output/duo-buildroot-sdk/linux_5.10/build/cv1812cp_milkv_duo256m_sd/arch/riscv/boot/Image
# -append "rootwait root=/dev/vda rw console=ttyS0" -drive file=output/duo-buildroot-sdk/buildroot-2021.05/output/milkv-duo256m_musl_riscv64/images/rootfs.ext2,format=raw,id=hd0
# -device virtio-blk-device,drive=hd0 -netdev user,id=net0 -device virtio-net-device,netdev=net0 -nographic
target_run() {
    local _q_image="$(find "$_dbr_path/out" -name "milkv-duo*.img" | head -n 1)"
    if [ -z "$_q_image" ]; then
        target_duo256
    fi
    local _q_image="$(find "$_dbr_path/out" -name "milkv-duo*.img" | head -n 1)"
    install_qemu
    install_firmware
    local _q_drive="-drive file=$_q_image,format=raw,if=virtio"
    $_qemu_binary $_q_cpu $_q_kernel $_q_main_opts $_q_net $_q_drive -append "$_q_append"
}

for arg in "$@"; do
    [[ $(type -t target_$arg) == function ]] && target_$arg || _fail "Not a valid argument $arg"
done
