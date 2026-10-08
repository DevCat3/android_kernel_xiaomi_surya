#!/usr/bin/env bash
# =============================================================================
#  Build Script — Xiaomi POCO X3 NFC (surya)
#  Source of truth: build.config.surya
#  Toolchain: Clang r383902 (local) + aarch64-linux-android GCC (fallback)
# =============================================================================

set -euo pipefail

# 
# Colors
# 
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

log()  { echo -e "${CYAN}[*]${RESET} $*"; }
ok()   { echo -e "${GREEN}[✓]${RESET} $*"; }
warn() { echo -e "${YELLOW}[!]${RESET} $*"; }
err()  { echo -e "${RED}[✗]${RESET} $*"; exit 1; }

# 
# Paths (from build.config.surya)
# 
KERNEL_DIR="$(cd "$(dirname "$0")" && pwd)"
OUT_DIR="${KERNEL_DIR}/out"
DIST_DIR="${KERNEL_DIR}/dist"

# In-tree toolchains
CLANG_BIN="${KERNEL_DIR}/toolchain/clang/host/linux-x86/clang-r383902/bin"
GCC64_BIN="${KERNEL_DIR}/toolchain/gcc/linux-x86/aarch64/aarch64-linux-android-4.9/bin"

# build.config.surya says CROSS_COMPILE=aarch64-elf-
# We map to in-tree aarch64-linux-android- (LLVM=1 means GCC is barely used)
CROSS_COMPILE="aarch64-linux-android-"
CROSS_COMPILE_ARM32="arm-linux-androideabi-"

# 
# build.config.surya — exact values
# 
ARCH="arm64"
DEFCONFIG="surya_defconfig"

# Artifacts (FILES= from build.config.surya)
ARTIFACTS=(
  "arch/arm64/boot/Image"
  "arch/arm64/boot/Image.gz"
  "arch/arm64/boot/dtbo.img"
  "arch/arm64/boot/dtb.img"
  "vmlinux"
)

JOBS=$(nproc --all)

# 
# Usage
# 
usage() {
  echo -e "${BOLD}Usage:${RESET} $(basename "$0") [OPTIONS]"
  echo ""
  echo "  -c, --clean       Full clean (rm -rf out/)"
  echo "  -d, --defconfig   Generate .config only, then exit"
  echo "  -m, --menuconfig  Open menuconfig"
  echo "  -j N              Parallel jobs (default: ${JOBS})"
  echo "  -h, --help        Show this help"
  echo ""
}

# 
# Argument parsing
# 
DO_CLEAN=0; ONLY_DEFCONFIG=0; DO_MENUCONFIG=0; DO_KSU=0; DO_ZIP=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    -c|--clean)      DO_CLEAN=1 ;;
    -d|--defconfig)  ONLY_DEFCONFIG=1 ;;
    -m|--menuconfig) DO_MENUCONFIG=1 ;;
    -j)              shift; JOBS="$1" ;;
    -h|--help)       usage; exit 0 ;;
    *)               warn "Unknown option: $1"; usage; exit 1 ;;
  esac
  shift
done

# 
# Sanity checks
# 
[[ -f "${KERNEL_DIR}/Makefile" ]] || err "Run this script from the kernel root."
[[ -d "${CLANG_BIN}" ]]           || err "Clang not found: ${CLANG_BIN}"
[[ -d "${GCC64_BIN}" ]]           || err "GCC64 not found: ${GCC64_BIN}"

export PATH="${CLANG_BIN}:${GCC64_BIN}:${PATH}"

command -v clang &>/dev/null || err "clang not in PATH after export"
CLANG_VER=$(clang --version | grep -oP 'clang \S+' | head -1)

if [[ ${DO_CLEAN} -eq 1 ]]; then
  log "Cleaning out/ ..."
  rm -rf "${OUT_DIR}"
  ok "Clean done."
fi

mkdir -p "${OUT_DIR}" "${DIST_DIR}"

MAKE_FLAGS=(
  O="${OUT_DIR}"
  ARCH="${ARCH}"

  # build.config.surya: CC=clang, LLVM=1, LLVM_IAS=1
  CC="clang"
  LLVM=1
  LLVM_IAS=1

  # Cross compile
  CROSS_COMPILE="${CROSS_COMPILE}"
  CROSS_COMPILE_ARM32="${CROSS_COMPILE_ARM32}"
  CLANG_TRIPLE="aarch64-linux-gnu-"

  # Full LLVM binutils (no GNU binutils needed with LLVM=1)
  LD="ld.lld"
  AR="llvm-ar"
  NM="llvm-nm"
  OBJCOPY="llvm-objcopy"
  OBJDUMP="llvm-objdump"
  READELF="llvm-readelf"
  STRIP="llvm-strip"

  # build.config.surya: DO_NOT_STRIP_MODULES=1
  INSTALL_MOD_STRIP=""

  -j"${JOBS}"
)

log "Generating .config from ${DEFCONFIG} ..."
make -C "${KERNEL_DIR}" "${MAKE_FLAGS[@]}" "${DEFCONFIG}"
ok ".config ready."

[[ ${ONLY_DEFCONFIG} -eq 1 ]] && { log "defconfig-only mode — done."; exit 0; }
 
if [[ ${DO_MENUCONFIG} -eq 1 ]]; then
  log "Opening menuconfig ..."
  make -C "${KERNEL_DIR}" "${MAKE_FLAGS[@]}" menuconfig
fi

log "Building kernel with ${JOBS} parallel jobs ..."
echo -e "${BOLD}────────────────────────────────────────────────────────${RESET}"
BUILD_START=$(date +%s)

make -C "${KERNEL_DIR}" "${MAKE_FLAGS[@]}" 2>&1 | tee "${OUT_DIR}/build.log"

BUILD_END=$(date +%s)
echo -e "${BOLD}────────────────────────────────────────────────────────${RESET}"
ELAPSED=$(( BUILD_END - BUILD_START ))
ELAPSED_FMT=$(printf '%dm:%02ds' $(( ELAPSED/60 )) $(( ELAPSED%60 )))

log "Collecting artifacts → dist/"
FOUND_ANY=0

for rel in "${ARTIFACTS[@]}"; do
  src="${OUT_DIR}/${rel}"
  if [[ -f "${src}" ]]; then
    cp "${src}" "${DIST_DIR}/"
    ok "  $(basename "${src}")"
    FOUND_ANY=1
  else
    warn "  Not produced (may be normal): ${rel}"
  fi
done

[[ ${FOUND_ANY} -eq 0 ]] && \
  err "No artifacts found — build likely failed. Check: ${OUT_DIR}/build.log"

# Collect .ko modules (build.config.surya: IN_KERNEL_MODULES=1, DO_NOT_STRIP_MODULES=1)
KO_COUNT=$(find "${OUT_DIR}" -name "*.ko" -maxdepth 8 2>/dev/null | wc -l)
if [[ ${KO_COUNT} -gt 0 ]]; then
  MODULES_DIST="${DIST_DIR}/modules"
  mkdir -p "${MODULES_DIST}"
  find "${OUT_DIR}" -name "*.ko" -maxdepth 8 -exec cp {} "${MODULES_DIST}/" \;
  ok "  ${KO_COUNT} kernel modules → dist/modules/"
fi

echo ""
echo -e "${GREEN}${BOLD}✓ Build complete — ${ELAPSED_FMT}${RESET}"
echo -e "  ${CYAN}Artifacts : ${DIST_DIR}/${RESET}"
echo -e "  ${CYAN}Build log : ${OUT_DIR}/build.log${RESET}"
