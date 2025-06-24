#!/bin/bash

# 颜色定义
info() {
  tput setaf 3  
  echo "[INFO] $1"
  tput sgr0
}

error() {
  tput setaf 1
  echo "[ERROR] $1"
  tput sgr0
  exit 1
}

# 参数设置
KERNEL_SUFFIX="-android14-TG@qdykernel"
ENABLE_KPM=true
ENABLE_LZ4KD=true

# 机型选择
info "请选择要编译的机型："
info "1. 一加 Ace 5"
info "2. 一加 12"
info "3. 一加 平板Pro"
read -p "输入选择 [1-3]: " device_choice

case $device_choice in
    1)
        DEVICE_NAME="oneplus_ace5"
        REPO_MANIFEST="oneplus_ace5.xml"
        ;;
    2)
        DEVICE_NAME="oneplus_12"
        REPO_MANIFEST="oneplus12_v.xml"
        ;;
    3)
        DEVICE_NAME="oneplus_pad_pro"
        REPO_MANIFEST="oneplus_pad_pro_v.xml"
        ;;
    *)
        error "无效的选择，请输入1-3之间的数字"
        ;;
esac

# 自定义补丁


read -p "输入内核名称修改(可改中文和emoji 回车默认): " input_suffix
[ -n "$input_suffix" ] && KERNEL_SUFFIX="$input_suffix"

read -p "是否启用kpm?(回车默认开启) [y/N]: " kpm
[[ "$kpm" =~ [yY] ]] && ENABLE_KPM=true

read -p "是否启用lz4+zstd?(回车默认开启) [y/N]: " lz4
[[ "$lz4" =~ [yY] ]] && ENABLE_LZ4KD=true

# 环境变量 - 按机型区分ccache目录
export CCACHE_COMPILERCHECK="%compiler% -dumpmachine; %compiler% -dumpversion"
export CCACHE_NOHASHDIR="true"
export CCACHE_HARDLINK="true"
export CCACHE_DIR="$HOME/.ccache_${DEVICE_NAME}"  # 改为按机型区分
export CCACHE_MAXSIZE="8G"

# ccache 初始化标志文件也按机型区分
CCACHE_INIT_FLAG="$CCACHE_DIR/.ccache_initialized"

# 初始化 ccache（仅第一次）
if command -v ccache >/dev/null 2>&1; then
    if [ ! -f "$CCACHE_INIT_FLAG" ]; then
        info "第一次为${DEVICE_NAME}初始化ccache..."
        mkdir -p "$CCACHE_DIR" || error "无法创建ccache目录"
        ccache -M "$CCACHE_MAXSIZE"
        touch "$CCACHE_INIT_FLAG"
    else
        info "ccache (${DEVICE_NAME}) 已初始化，跳过..."
    fi
else
    info "未安装 ccache，跳过初始化"
fi

# 工作目录 - 按机型区分
WORKSPACE="$HOME/kernel_${DEVICE_NAME}"
mkdir -p "$WORKSPACE" || error "无法创建工作目录"
cd "$WORKSPACE" || error "无法进入工作目录"

# 检查并安装依赖
info "检查并安装依赖..."
DEPS=(python3 git curl ccache flex bison libssl-dev libelf-dev bc zip)
MISSING_DEPS=()

for pkg in "${DEPS[@]}"; do
    if ! dpkg -s "$pkg" >/dev/null 2>&1; then
        MISSING_DEPS+=("$pkg")
    fi
done

if [ ${#MISSING_DEPS[@]} -eq 0 ]; then
    info "所有依赖已安装，跳过安装。"
else
    info "缺少依赖：${MISSING_DEPS[*]}，正在安装..."
    sudo apt update || error "系统更新失败"
    sudo apt install -y "${MISSING_DEPS[@]}" || error "依赖安装失败"
fi

# 配置 Git（仅在未配置时）
info "检查 Git 配置..."

GIT_NAME=$(git config --global user.name || echo "")
GIT_EMAIL=$(git config --global user.email || echo "")

if [ -z "$GIT_NAME" ] || [ -z "$GIT_EMAIL" ]; then
    info "Git 未配置，正在设置..."
    git config --global user.name "Q1udaoyu"
    git config --global user.email "sucisama2888@gmail.com"
else
    info "Git 已配置："
fi

# 安装repo工具（仅首次）
if ! command -v repo >/dev/null 2>&1; then
    info "安装repo工具..."
    curl -fsSL https://storage.googleapis.com/git-repo-downloads/repo > ~/repo || error "repo下载失败"
    chmod a+x ~/repo
    sudo mv ~/repo /usr/local/bin/repo || error "repo安装失败"
else
    info "repo工具已安装，跳过安装"
fi

# ==================== 源码管理 ====================

# 创建源码目录
KERNEL_WORKSPACE="$WORKSPACE/kernel_workspace"

mkdir -p "$KERNEL_WORKSPACE" || error "无法创建kernel_workspace目录"

cd "$KERNEL_WORKSPACE" || error "无法进入kernel_workspace目录"

# 初始化源码
info "初始化repo并同步源码..."
repo init -u https://github.com/OnePlusOSS/kernel_manifest.git -b refs/heads/oneplus/sm8650 -m "$REPO_MANIFEST" --depth=1 || error "repo初始化失败"
repo --trace sync -c -j$(nproc --all) --no-tags || error "repo同步失败"

# ==================== 核心构建步骤 ====================

info "清理dirty脏块及ABI保护..."
# 清理abi保护
for d in kernel_platform/common kernel_platform/msm-kernel; do
  rm "$d"/android/abi_gki_protected_exports_* 2>/dev/null || echo "No protected exports in $d!"
done
# 移除dirty脏块
for f in kernel_platform/{common,msm-kernel,external/dtc}/scripts/setlocalversion; do
  sed -i 's/ -dirty//g' "$f"
  grep -q 'res=.*s/-dirty' "$f" || sed -i '$i res=$(echo "$res" | sed '\''s/-dirty//g'\'')' "$f"
done
# 修改内核名
info "修改内核名..."
sed -i '$s|echo "\$res"|echo "$KERNEL_SUFFIX"|' kernel_platform/common/scripts/setlocalversion            
sed -i '$s|echo "\$res"|echo "$KERNEL_SUFFIX"|' kernel_platform/msm-kernel/scripts/setlocalversion
sed -i '$s|echo "\$res"|echo "$KERNEL_SUFFIX"|' kernel_platform/external/dtc/scripts/setlocalversion


# 设置SukiSU
info "设置SukiSU..."
cd kernel_platform || error "进入kernel_platform失败"
curl -LSs "https://raw.githubusercontent.com/SukiSU-Ultra/SukiSU-Ultra/main/kernel/setup.sh" | bash -s susfs-main
cd KernelSU || error "进入KernelSU目录失败"
KSU_VERSION=$(expr $(/usr/bin/git rev-list --count main) "+" 10700)
export KSU_VERSION=$KSU_VERSION
sed -i "s/DKSU_VERSION=12800/DKSU_VERSION=${KSU_VERSION}/" kernel/Makefile || error "修改KernelSU版本失败"

# 设置susfs
info "设置susfs..."
cd "$KERNEL_WORKSPACE" || error "返回工作目录失败"
git clone https://gitlab.com/simonpunk/susfs4ksu.git -b gki-android14-6.1 || info "susfs4ksu已存在或克隆失败"
git clone https://github.com/Xiaomichael/kernel_patches.git || info "susfs4ksu已存在或克隆失败"
git clone -q https://github.com/SukiSU-Ultra/SukiSU_patch.git || info "SukiSU_patch已存在或克隆失败"

cd kernel_platform || error "进入kernel_platform失败"
cp ../susfs4ksu/kernel_patches/50_add_susfs_in_gki-android14-6.1.patch ./common/
cp ../kernel_patches/next/syscall_hooks.patch ./common/
cp ../susfs4ksu/kernel_patches/fs/* ./common/fs/
cp ../susfs4ksu/kernel_patches/include/linux/* ./common/include/linux/

if [ "${ENABLE_LZ4KD}" == "true" ]; then
    cp ../kernel_patches/001-lz4.patch ./common/
    cp ../kernel_patches/lz4armv8.S ./common/lib
    cp ../kernel_patches/002-zstd.patch ./common/
fi

cd $KERNEL_WORKSPACE/kernel_platform/common || { echo "进入common目录失败"; exit 1; }

patch -p1 < 50_add_susfs_in_gki-android14-6.1.patch || true
cp ../../kernel_patches/69_hide_stuff.patch ./
patch -p1 -F 3 < 69_hide_stuff.patch
patch -p1 -F 3 < syscall_hooks.patch

if [ "${ENABLE_LZ4KD}" == "true" ]; then
    git apply -p1 < 001-lz4.patch || true
    patch -p1 < 002-zstd.patch || true
fi

cd $KERNEL_WORKSPACE/kernel_platform
# 添加SUSFS配置
info "添加SUSFS配置..."
# 定义 defconfig 路径
DEFCONFIG=./common/arch/arm64/configs/gki_defconfig
# 写入基础配置
cat <<EOF >> "$DEFCONFIG"
CONFIG_KSU=y
CONFIG_KSU_SUSFS_SUS_SU=n
CONFIG_KSU_MANUAL_HOOK=y
CONFIG_KSU_SUSFS=y
CONFIG_KSU_SUSFS_HAS_MAGIC_MOUNT=y
CONFIG_KSU_SUSFS_SUS_PATH=y
CONFIG_KSU_SUSFS_SUS_MOUNT=y
CONFIG_KSU_SUSFS_AUTO_ADD_SUS_KSU_DEFAULT_MOUNT=y
CONFIG_KSU_SUSFS_AUTO_ADD_SUS_BIND_MOUNT=y
CONFIG_KSU_SUSFS_SUS_KSTAT=y
CONFIG_KSU_SUSFS_SUS_OVERLAYFS=n
CONFIG_KSU_SUSFS_TRY_UMOUNT=y
CONFIG_KSU_SUSFS_AUTO_ADD_TRY_UMOUNT_FOR_BIND_MOUNT=y
CONFIG_KSU_SUSFS_SPOOF_UNAME=y
CONFIG_KSU_SUSFS_ENABLE_LOG=y
CONFIG_KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS=y
CONFIG_KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG=y
CONFIG_KSU_SUSFS_OPEN_REDIRECT=y
CONFIG_TCP_CONG_ADVANCED=y
CONFIG_TCP_CONG_BBR=y
CONFIG_NET_SCH_FQ=y
CONFIG_TCP_CONG_BIC=n
CONFIG_TCP_CONG_WESTWOOD=n
CONFIG_TCP_CONG_HTCP=n
EOF

# 可选配置：KPM
if [ "${ENABLE_KPM}" = "true" ]; then
  echo "CONFIG_KPM=y" >> "$DEFCONFIG"
fi

# 移除 check_defconfig（禁用 sanity check）
sed -i 's/check_defconfig//' ./common/build.config.gki

# 构建内核
info "开始构建内核..."
#!/bin/bash
set -e

# 设置工具链路径
export CLANG_PATH="$KERNEL_WORKSPACE/kernel_platform/prebuilts/clang/host/linux-x86/clang-r487747c/bin"
export RUSTC_PATH="$KERNEL_WORKSPACE/kernel_platform/prebuilts/rust/linux-x86/1.73.0b/bin/rustc"
export PAHOLE_PATH="$KERNEL_WORKSPACE/kernel_platform/prebuilts/kernel-build-tools/linux-x86/bin/pahole"
export PATH="$CLANG_PATH:/usr/lib/ccache:$PATH"

# 进入源码目录
cd $KERNEL_WORKSPACE/kernel_platform/common

# 配置内核
make LLVM=1 ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- CC=clang \
  RUSTC="$RUSTC_PATH" \
  PAHOLE="$PAHOLE_PATH" \
  LD=ld.lld HOSTLD=ld.lld \
  O=out KCFLAGS+=-O2 \
  CONFIG_LTO_CLANG=y CONFIG_LTO_CLANG_THIN=y CONFIG_LTO_CLANG_FULL=n CONFIG_LTO_NONE=n \
  gki_defconfig

# 编译内核镜像
make -j$(nproc) LLVM=1 ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- CC=clang \
  RUSTC="$RUSTC_PATH" \
  PAHOLE="$PAHOLE_PATH" \
  LD=ld.lld HOSTLD=ld.lld \
  O=out KCFLAGS+=-O2 Image



if [ "${ENABLE_KPM}" = "true" ]; then
    # 应用Linux补丁
    info "应用KPM补丁..."
    cd out/arch/arm64/boot || error "进入boot目录失败"
    curl -LO https://github.com/SukiSU-Ultra/SukiSU_KernelPatch_patch/releases/download/0.12.0/patch_linux || error "下载patch_linux失败"
    chmod +x patch_linux
    ./patch_linux || error "应用patch_linux失败"
    rm -f Image
    mv oImage Image || error "替换Image失败"
fi

# 创建AnyKernel3包
info "创建AnyKernel3包..."
cd "$WORKSPACE" || error "返回工作目录失败"
git clone -q https://github.com/showdo/AnyKernel3.git --depth=1 || info "AnyKernel3已存在"
rm -rf ./AnyKernel3/.git
rm -f ./AnyKernel3/push.sh
cp "$KERNEL_WORKSPACE/kernel_platform/common/out/arch/arm64/boot/Image" ./AnyKernel3/ || error "复制Image失败"

# 打包
cd AnyKernel3 || error "进入AnyKernel3目录失败"
zip -r "AnyKernel3_${KSU_VERSION}_${DEVICE_NAME}_SuKiSu.zip" ./* || error "打包失败"

# 创建C盘输出目录（通过WSL访问Windows的C盘）
WIN_OUTPUT_DIR="/mnt/c/Kernel_Build/${DEVICE_NAME}/"
mkdir -p "$WIN_OUTPUT_DIR" || error "无法创建Windows目录，可能未挂载C盘，将保存到Linux目录:$WORKSPACE/AnyKernel3/AnyKernel3_${KSU_VERSION}_${DEVICE_NAME}_SuKiSu.zip"

# 复制Image和AnyKernel3包
cp "$KERNEL_WORKSPACE/kernel_platform/common/out/arch/arm64/boot/Image" "$WIN_OUTPUT_DIR/"
cp "$WORKSPACE/AnyKernel3/AnyKernel3_${KSU_VERSION}_${DEVICE_NAME}_SuKiSu.zip" "$WIN_OUTPUT_DIR/"

info "内核包路径: C:/Kernel_Build/${DEVICE_NAME}/AnyKernel3_${KSU_VERSION}_${DEVICE_NAME}_SuKiSu.zip"
info "Image路径: C:/Kernel_Build/${DEVICE_NAME}/Image"
info "请在C盘目录中查找内核包和Image文件。"
info "清理本次构建的所有文件..."
sudo rm -rf "$WORKSPACE" || error "无法删除工作目录，可能未创建"
info "清理完成！下次运行脚本将重新拉取源码并构建内核。"
