#!/bin/bash
#
# Compile script for Xiaomi 8450 kernel, dts and modules with AOSPA
# Copyright (C) 2024-2025 Adithya R.

SECONDS=0 # start builtin bash timer
KP_ROOT="$(realpath ../..)"
TC_DIR="$KP_ROOT/prebuilts-master/clang/host/linux-x86/clang-r510928"
PREBUILTS_DIR="$KP_ROOT/prebuilts/kernel-build-tools/linux-x86"
BRANCH="$(git branch --show-current)"
MODULES_REPO="sm8450-modules"
DT_REPO="sm8450-devicetrees"

DO_CLEAN=false
NO_LTO=false
ONLY_CONFIG=false
ONLY_KERNEL=false
ONLY_DTB=false
ONLY_MODULES=false
TARGET=
DTB_WILDCARD="*"
DTBO_WILDCARD="*"

while [ $# -gt 0 ]; do
    case "$1" in
        -c | --clean) DO_CLEAN=true ;;
        -n | --no-lto) NO_LTO=true ;;
        -o | --only-config) ONLY_CONFIG=true ;;
        -k | --only-kernel) ONLY_KERNEL=true ;;
        -d | --only-dtb) ONLY_DTB=true ;;
        -m | --only-modules) ONLY_MODULES=true ;;
        --ksunext ) KSUNEXT_ENABLE=true ;;
        --sukisu ) SUKISU_ENABLE=true ;;
        --susfs ) SUSFS_ENABLE=true ;;
        *) TARGET="$1" ;;
    esac
    shift
done

if [ -z "$TARGET" ]; then
    echo "Target (device) not specified!"
    exit 1
fi

if [[ $KSUNEXT_ENABLE && $SUKISU_ENABLE ]]; then
  echo "Enable only either KSU Next (--ksun) or SukiSU (--sukisu)"
  exit 1
fi

if ! source .build.rc || [ -z "$SRC_ROOT" ]; then
    echo -e "Create a .build.rc file here and define\nSRC_ROOT=<path/to/aospa/source>"
    exit 1
fi

KERNEL_DIR="$SRC_ROOT/device/xiaomi/$TARGET-kernel"

if [ ! -d "$KERNEL_DIR" ]; then
    echo "$KERNEL_DIR does not exist!"
    exit 1
fi

KERNEL_COPY_TO="$KERNEL_DIR"
DTB_COPY_TO="$KERNEL_DIR/dtbs"
DTBO_COPY_TO="$DTB_COPY_TO/dtbo.img"
VBOOT_DIR="$KERNEL_DIR/vendor_ramdisk"
VDLKM_DIR="$KERNEL_DIR/vendor_dlkm"

DEFCONFIG="gki_defconfig"
DEFCONFIGS="vendor/waipio_GKI.config \
vendor/xiaomi_GKI.config \
vendor/westwood.config \
vendor/debugfs.config"

if [ $SUSFS_ENABLE ]; then
  DEFCONFIGS+=" vendor/susfs.config"
fi

MODULES_SRC="../$MODULES_REPO/qcom/opensource"
MODULES="mmrm-driver \
audio-kernel \
camera-kernel \
cvp-kernel \
dataipa/drivers/platform/msm \
datarmnet/core \
datarmnet-ext/aps \
datarmnet-ext/offload \
datarmnet-ext/shs \
datarmnet-ext/perf \
datarmnet-ext/perf_tether \
datarmnet-ext/sch \
datarmnet-ext/wlan \
display-drivers/msm \
eva-kernel \
video-driver \
wlan/qcacld-3.0/.qca6490"

case "$TARGET" in
    "marble" )
        DTB_WILDCARD="ukee"
        DTBO_WILDCARD="marble-sm7475-pm8008-overlay"
        ;;
    "cupid" )
        DTB_WILDCARD="waipio"
        DTBO_WILDCARD="cupid-sm8450-pm8008-overlay"
        ;;
esac

##
## Helper functions
##

echo_i() { echo -e "\n\033[1;36m==> $1\033[0m\n"; }

echo_w() { echo -e "\033[1;33m $1\033[0m"; }

echo_e() { echo -e "\n\033[1;31m $1\033[0m\n"; }

get_trees_rev() {
    kernel_rev="$(git rev-parse HEAD | cut -c1-10)"
    [[ -n "$(git --no-optional-locks status -uno --porcelain)" ]] && kernel_rev+="+"

    modules_rev="$(git -C ../$MODULES_REPO rev-parse HEAD | cut -c1-8)"
    [[ -n "$(git -C ../$MODULES_REPO --no-optional-locks status -uno --porcelain)" ]] && modules_rev+="+"

    dt_rev="$(git -C ../$DT_REPO rev-parse HEAD | cut -c1-8)"
    [[ -n "$(git -C ../$DT_REPO --no-optional-locks status -uno --porcelain)" ]] && dt_rev+="+"

    echo "-${kernel_rev}-m${modules_rev}-d${dt_rev}"
}

m() {
    make -j$(nproc --all) O=out ARCH=arm64 LLVM=1 LLVM_IAS=1 \
        DTC_EXT="$PREBUILTS_DIR/bin/dtc" \
        DTC_OVERLAY_TEST_EXT="$PREBUILTS_DIR/bin/ufdt_apply_overlay" \
        TARGET_PRODUCT=$TARGET $@ || exit $?
}

build_kernel() {
    echo_i "Building kernel image..."
    m Image
    cp out/arch/arm64/boot/Image $KERNEL_COPY_TO
    echo_i "Copied kernel to $KERNEL_COPY_TO."
}

build_modules() {
    echo_i "Building kernel modules..."
    m modules
    rm -rf out/modules out/*.ko
    m INSTALL_MOD_PATH=modules INSTALL_MOD_STRIP=1 modules_install

    ksu_path="$(find $modules_out -name 'kernelsu.ko' -print -quit)"
    if [ -n "$ksu_path" ]; then
        mv "$ksu_path" out
        echo_i "Copied to out/kernelsu.ko"
    else
        echo_e "Unable to locate ksu module!"
    fi

    echo_i "Building techpack modules..."
    for module in $MODULES; do
        echo -e "\nBuilding $module..."
        m -C $MODULES_SRC/$module M=$MODULES_SRC/$module KERNEL_SRC="$(pwd)" OUT_DIR="$(pwd)/out"
        m -C $MODULES_SRC/$module M=$MODULES_SRC/$module KERNEL_SRC="$(pwd)" OUT_DIR="$(pwd)/out" \
            INSTALL_MOD_PATH=modules INSTALL_MOD_STRIP=1 modules_install
    done

    first_stage_modules="$(cat modules.list.msm.waipio)"
    second_stage_modules="$(cat modules.list.second_stage modules.list.second_stage.$TARGET)"
    vendor_dlkm_modules="$(cat modules.list.vendor_dlkm modules.list.vendor_dlkm.$TARGET)"
    modules_out="out/modules/lib/modules/$(ls -t out/modules/lib/modules/ | head -n1)"

    rm -rf $VBOOT_DIR && mkdir -p $VBOOT_DIR
    rm -rf $VDLKM_DIR && mkdir -p $VDLKM_DIR

    echo_i "Copying first stage modules..."
    for module in $first_stage_modules; do
        mod_path=$(find $modules_out -name "$module" -print -quit)
        if [ -z "$mod_path" ]; then
            echo_w "Could not locate $module, skipping!"
            continue
        fi
        cp $mod_path $VBOOT_DIR
        echo $module >> $VBOOT_DIR/modules.load
        echo $module >> $VBOOT_DIR/modules.load.recovery
        echo $module
    done

    echo_i "Copying second stage modules..."
    for module in $second_stage_modules; do
        mod_path=$(find $modules_out -name "$module" -print -quit)
        if [ -z "$mod_path" ]; then
            echo_w "Could not locate $module, skipping!"
            continue
        fi
        cp $mod_path $VBOOT_DIR
        cp $mod_path $VDLKM_DIR
        echo $module >> $VBOOT_DIR/modules.load.recovery
        echo $module >> $VDLKM_DIR/modules.load
        echo $module
    done

    echo_i "Copying vendor_dlkm modules..."
    for module in $vendor_dlkm_modules; do
        mod_path=$(find $modules_out -name "$module" -print -quit)
        if [ -z "$mod_path" ]; then
            echo_w "Could not locate $module, skipping!"
            continue
        fi
        cp $mod_path $VDLKM_DIR
        echo $module >> $VDLKM_DIR/modules.load
        echo $module
    done

    for dest_dir in $VBOOT_DIR $VDLKM_DIR; do
        cp modules.vendor_blocklist.msm.waipio $dest_dir/modules.blocklist
        cp $modules_out/modules.{alias,dep,softdep} $dest_dir
    done

    sed -E -i 's|([^: ]*/)([^/]*\.ko)([:]?)([ ]\|$)|/lib/modules/\2\3\4|g' $VBOOT_DIR/modules.dep
    sed -E -i 's|([^: ]*/)([^/]*\.ko)([:]?)([ ]\|$)|/vendor_dlkm/lib/modules/\2\3\4|g' $VDLKM_DIR/modules.dep
}

build_dtbs() {
    echo_i "Building dtbs..."
    m dtbs

    rm -rf out/dtbs{,-base}
    mkdir out/dtbs{,-base}
    mv  out/arch/arm64/boot/dts/vendor/qcom/$DTB_WILDCARD.dtb \
        out/arch/arm64/boot/dts/vendor/qcom/$DTBO_WILDCARD.dtbo \
        out/dtbs-base
    rm -f out/arch/arm64/boot/dts/vendor/qcom/*.dtbo
    ../../build/android/merge_dtbs.py out/dtbs-base out/arch/arm64/boot/dts/vendor/qcom/ out/dtbs || exit $?

    if [ -d "$DTB_COPY_TO" ]; then
        rm -f $DTB_COPY_TO/*.dtb
        cp out/dtbs/*.dtb $DTB_COPY_TO
    else
        rm -f $DTB_COPY_TO
        cat out/dtbs/*.dtb >> $DTB_COPY_TO
    fi
    echo_i "Copied dtb(s) to $DTB_COPY_TO."

    mkdtboimg.py create $DTBO_COPY_TO --page_size=4096 out/dtbs/*.dtbo
    echo_i "Generated dtbo.img to $DTBO_COPY_TO".
}

setup_susfs() {
    git clone https://gitlab.com/simonpunk/susfs4ksu/ -b gki-android12-5.10
    if [ ! -z $1 ]; then
      (cd susfs4ksu && git checkout $1)
    fi
    cp -r susfs4ksu/kernel_patches/* .
    patch -p1 < 50*.patch
    rm -rf susfs4ksu
}

##
## Main logic starts here
##

export PATH="$TC_DIR/bin:$PREBUILTS_DIR/bin:$PATH"
export LOCALVERSION="$(get_trees_rev)"

$DO_CLEAN && {
    rm -rf out $MODULES_REPO
    echo_i "Cleaned output directories."
}

rmdir KernelSU

# KSUNext
if [ $KSUNEXT_ENABLE ]; then
  echo_i "Installing KernelSU Next..."
  curl -LSs "https://raw.githubusercontent.com/tiltshiftfocus/KernelSU-Next/next-susfs/kernel/setup.sh" | bash -s next-susfs
  rmdir KernelSU
  if [ $SUSFS_ENABLE ]; then
    setup_susfs 0ed20c1656af7806a1760837ad320e62a8fb40fd
  fi
  CUSTOM_KSU=true
fi
# SukiSU test
if [ $SUKISU_ENABLE ]; then
  echo_i -e "Installing SukiSU..."
  curl -LSs "https://raw.githubusercontent.com/SukiSU-Ultra/SukiSU-Ultra/main/kernel/setup.sh" | bash -s tmp-builtin
  if [ $SUSFS_ENABLE ]; then
    setup_susfs
  fi
  CUSTOM_KSU=true
fi

# If no KSUNext or SukiSU selected, patch SuSFS into official KernelSU
if [[ $SUSFS_ENABLE && (! $KSUNEXT_ENABLE && ! $SUKISU_ENABLE) ]]; then
  curl -LSs "https://raw.githubusercontent.com/tiann/KernelSU/main/kernel/setup.sh" | bash -s 3d73f89
  setup_susfs
  (cd KernelSU && patch -p1 < 10_enable_susfs_for_ksu.patch)
  CUSTOM_KSU=true
fi

# If none of the above, just setup only official KernelSU
if [ ! $CUSTOM_KSU ]; then
  curl -LSs "https://raw.githubusercontent.com/tiann/KernelSU/main/kernel/setup.sh" | bash -
fi


mkdir -p out

echo_i "Generating config..."
m $DEFCONFIG
m ./scripts/kconfig/merge_config.sh $DEFCONFIGS vendor/${TARGET}_GKI.config

if [ $SUSFS_ENABLE ]; then
  scripts/config --file out/.config \
      --set-str LOCALVERSION "-vauxite" \
      -d LOCALVERSION_AUTO
else
  scripts/config --file out/.config \
      --set-str LOCALVERSION "-vauxite" \
      -d LOCALVERSION_AUTO \
      -m KSU
fi

$NO_LTO && {
    scripts/config --file out/.config \
        --set-str LOCALVERSION "-vauxite-nolto" \
        -d LTO_CLANG_FULL -e LTO_NONE
    echo_i "Disabled LTO!"
}

$ONLY_CONFIG && exit

if $ONLY_KERNEL; then build_kernel
elif $ONLY_DTB; then build_dtbs
elif $ONLY_MODULES; then build_modules
else {
    build_kernel
    build_modules
    build_dtbs
}; fi


echo_i "Completed in $((SECONDS / 60)) minute(s) and $((SECONDS % 60)) second(s) !"
