#!/usr/bin/env bash
# =============================================================================
#  ClaudeOS Builder — 独自 Linux ディストリビューション ビルドスクリプト
#  ホスト: Ubuntu 24.04 (apt/dpkg を使用)
# =============================================================================
set -euo pipefail

# ── カラー出力 ────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

log()  { echo -e "${GREEN}[✓]${RESET} $*"; }
info() { echo -e "${CYAN}[→]${RESET} $*"; }
warn() { echo -e "${YELLOW}[!]${RESET} $*"; }
die()  { echo -e "${RED}[✗] $*${RESET}" >&2; exit 1; }
banner() {
  echo -e "\n${BOLD}${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
  echo -e "${BOLD}${CYAN}  $*${RESET}"
  echo -e "${BOLD}${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}\n"
}

# ── 設定 ─────────────────────────────────────────────────────────────────────
DISTRO_NAME="ClaudeOS"
DISTRO_VERSION="1.0"
DISTRO_CODENAME="aurora"
ARCH="amd64"
SUITE="noble"           # Ubuntu 24.04 base
MIRROR="http://archive.ubuntu.com/ubuntu"

WORK_DIR=""
CHROOT_DIR="${WORK_DIR}/chroot"
ISO_DIR="${WORK_DIR}/iso"
OUTPUT_ISO="${WORK_DIR}/${DISTRO_NAME}-${DISTRO_VERSION}-${ARCH}.iso"

# インストールするパッケージ
BASE_PACKAGES="systemd,systemd-sysv,udev,dbus,bash,coreutils,util-linux,procps,\
grep,sed,gawk,findutils,diffutils,file,less,more,nano,\
apt,dpkg,debianutils,\
network-manager,iproute2,iputils-ping,curl,wget,\
openssh-client,\
tar,gzip,bzip2,xz-utils,zip,unzip,\
python3,python3-pip,\
sudo,passwd,adduser,\
lsb-release,ca-certificates,\
htop,neofetch,\
linux-image-generic,linux-headers-generic,grub-pc"

# ── 前提チェック ──────────────────────────────────────────────────────────────
check_prerequisites() {
  banner "前提条件チェック"
  local tools=(debootstrap mksquashfs xorriso grub-mkrescue)
  for t in "${tools[@]}"; do
    if command -v "$t" &>/dev/null; then
      log "  $t — OK"
    else
      die "$t が見つかりません。先にインストールしてください。"
    fi
  done
  [[ $EUID -eq 0 ]] || die "root 権限が必要です。"
  log "全ての前提条件を満たしています"
}

# ── ディレクトリ準備 ──────────────────────────────────────────────────────────
prepare_dirs() {
  banner "ディレクトリ準備"
  rm -rf "${WORK_DIR}"
  mkdir -p "${CHROOT_DIR}" "${ISO_DIR}/boot/grub" "${ISO_DIR}/live"
  log "作業ディレクトリを作成: ${WORK_DIR}"
}

# ── Step 1: debootstrap でベースシステム構築 ──────────────────────────────────
build_base() {
  banner "Step 1: ベースシステム構築 (debootstrap)"
  info "Ubuntu ${SUITE} のベースシステムを ${CHROOT_DIR} に展開中..."
  debootstrap \
    --arch="${ARCH}" \
    --include="${BASE_PACKAGES}" \
    --components=main,restricted,universe \
    "${SUITE}" \
    "${CHROOT_DIR}" \
    "${MIRROR}" \
    2>&1 | grep -E "^(I:|W:|E:)" || true
  log "ベースシステム構築完了"
}

# ── Step 2: chroot 内設定 ─────────────────────────────────────────────────────
configure_chroot() {
  banner "Step 2: システム設定 (chroot)"

  # /proc /sys /dev のマウント
  for fs in proc sys dev dev/pts; do
    mount --bind "/${fs}" "${CHROOT_DIR}/${fs}" 2>/dev/null || true
  done

  # resolv.conf
  cp /etc/resolv.conf "${CHROOT_DIR}/etc/resolv.conf" 2>/dev/null || true

  # ─── chroot 内スクリプト生成 ──────────────────────────────────────────────
  cat > "${CHROOT_DIR}/tmp/setup.sh" << 'CHROOT_EOF'
#!/bin/bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
export LANG=en_US.UTF-8

echo "[chroot] APT sources 設定..."
cat > /etc/apt/sources.list << 'APT_EOF'
deb http://archive.ubuntu.com/ubuntu noble main restricted universe multiverse
deb http://archive.ubuntu.com/ubuntu noble-updates main restricted universe multiverse
deb http://security.ubuntu.com/ubuntu noble-security main restricted universe multiverse
APT_EOF

echo "[chroot] APT 更新..."
apt-get update -q

echo "[chroot] ロケール設定..."
apt-get install -y -q locales
echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen
echo "ja_JP.UTF-8 UTF-8" >> /etc/locale.gen
locale-gen
update-locale LANG=en_US.UTF-8

echo "[chroot] タイムゾーン設定..."
ln -sf /usr/share/zoneinfo/Asia/Tokyo /etc/localtime
echo "Asia/Tokyo" > /etc/timezone

echo "[chroot] ホスト名設定..."
echo "claudeos" > /etc/hostname
cat > /etc/hosts << 'HOSTS_EOF'
127.0.0.1   localhost
127.0.1.1   claudeos
::1         localhost ip6-localhost ip6-loopback
HOSTS_EOF

echo "[chroot] ユーザー設定..."
# root パスワード: claudeos
echo "root:claudeos" | chpasswd
# 一般ユーザー作成
useradd -m -s /bin/bash -G sudo,adm claude 2>/dev/null || true
echo "claude:claude" | chpasswd
echo "claude ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/claude

echo "[chroot] ネットワーク設定..."
cat > /etc/netplan/01-network.yaml << 'NET_EOF'
network:
  version: 2
  renderer: networkd
  ethernets:
    eth0:
      dhcp4: true
      optional: true
NET_EOF

echo "[chroot] systemd サービス設定..."
systemctl enable NetworkManager 2>/dev/null || true
systemctl enable ssh 2>/dev/null || true
systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target 2>/dev/null || true

echo "[chroot] /etc/os-release カスタマイズ..."
cat > /etc/os-release << 'OS_EOF'
NAME="ClaudeOS"
VERSION="1.0 (Aurora)"
ID=claudeos
ID_LIKE=ubuntu
VERSION_ID="1.0"
PRETTY_NAME="ClaudeOS 1.0 (Aurora)"
VERSION_CODENAME=aurora
HOME_URL="https://claudeos.example.org/"
SUPPORT_URL="https://claudeos.example.org/support"
BUG_REPORT_URL="https://claudeos.example.org/bugs"
OS_EOF

echo "[chroot] /etc/issue カスタマイズ..."
cat > /etc/issue << 'ISSUE_EOF'

  ██████╗██╗      █████╗ ██╗   ██╗██████╗ ███████╗ ██████╗ ███████╗
 ██╔════╝██║     ██╔══██╗██║   ██║██╔══██╗██╔════╝██╔═══██╗██╔════╝
 ██║     ██║     ███████║██║   ██║██║  ██║█████╗  ██║   ██║███████╗
 ██║     ██║     ██╔══██║██║   ██║██║  ██║██╔══╝  ██║   ██║╚════██║
 ╚██████╗███████╗██║  ██║╚██████╔╝██████╔╝███████╗╚██████╔╝███████║
  ╚═════╝╚══════╝╚═╝  ╚═╝ ╚═════╝ ╚═════╝ ╚══════╝ ╚═════╝ ╚══════╝

  ClaudeOS 1.0 "Aurora" — Built with ❤ on Ubuntu base
  Login: claude / Password: claude  |  root / Password: claudeos

ISSUE_EOF

echo "[chroot] neofetch カスタム設定..."
mkdir -p /etc/neofetch
cat > /etc/neofetch/config.conf << 'NEO_EOF'
print_info() {
  info title
  info underline
  info "OS" distro
  info "Kernel" kernel
  info "Uptime" uptime
  info "Shell" shell
  info "CPU" cpu
  info "Memory" memory
}
ascii_distro="auto"
NEO_EOF

echo "[chroot] カスタム MOTD..."
rm -f /etc/update-motd.d/*
cat > /etc/update-motd.d/00-claudeos << 'MOTD_EOF'
#!/bin/bash
echo ""
echo "  ╔═══════════════════════════════════════════╗"
echo "  ║   Welcome to ClaudeOS 1.0 'Aurora'       ║"
echo "  ║   Powered by Ubuntu Noble base           ║"
echo "  ╚═══════════════════════════════════════════╝"
echo ""
MOTD_EOF
chmod +x /etc/update-motd.d/00-claudeos

echo "[chroot] APT クリーンアップ..."
apt-get clean
rm -rf /var/lib/apt/lists/*
rm -f /tmp/setup.sh

echo "[chroot] セットアップ完了!"
CHROOT_EOF

  chmod +x "${CHROOT_DIR}/tmp/setup.sh"
  info "chroot 内でシステム設定スクリプトを実行中..."
  chroot "${CHROOT_DIR}" /tmp/setup.sh
  log "chroot 設定完了"

  # アンマウント
  for fs in dev/pts dev sys proc; do
    umount -lf "${CHROOT_DIR}/${fs}" 2>/dev/null || true
  done
}

# ── Step 3: カスタムパッケージマネージャラッパー作成 ──────────────────────────
create_pkg_manager() {
  banner "Step 3: カスタムパッケージマネージャ (cos-pkg) 作成"

  cat > "${CHROOT_DIR}/usr/local/bin/cos-pkg" << 'PKG_EOF'
#!/bin/bash
# ============================================================
#  cos-pkg — ClaudeOS Package Manager
#  apt/dpkg のフロントエンドラッパー
# ============================================================
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

VERSION="1.0.0"
LOG_FILE="/var/log/cos-pkg.log"

_log() { echo "$(date '+%Y-%m-%d %T') $*" >> "${LOG_FILE}" 2>/dev/null || true; }
ok()   { echo -e "${GREEN}✓${RESET} $*"; }
err()  { echo -e "${RED}✗ $*${RESET}" >&2; }
inf()  { echo -e "${CYAN}→${RESET} $*"; }

usage() {
  cat << HELP
${BOLD}cos-pkg${RESET} — ClaudeOS Package Manager v${VERSION}

${BOLD}使い方:${RESET}
  cos-pkg <コマンド> [オプション]

${BOLD}コマンド:${RESET}
  install  <pkg...>   パッケージをインストール
  remove   <pkg...>   パッケージを削除
  update              パッケージリストを更新
  upgrade             全パッケージをアップグレード
  search   <keyword>  パッケージを検索
  info     <pkg>      パッケージ情報を表示
  list                インストール済みパッケージ一覧
  clean               キャッシュをクリーンアップ
  check               システムの整合性チェック
  history             インストール履歴を表示
  version             バージョン表示

${BOLD}例:${RESET}
  cos-pkg install vim git
  cos-pkg search python3
  cos-pkg update && cos-pkg upgrade
HELP
}

require_root() {
  [[ $EUID -eq 0 ]] || { err "このコマンドは root 権限が必要です。sudo を使ってください。"; exit 1; }
}

cmd_install() {
  require_root
  [[ ${#@} -gt 0 ]] || { err "パッケージ名を指定してください。"; exit 1; }
  inf "インストール中: $*"
  _log "install: $*"
  DEBIAN_FRONTEND=noninteractive apt-get install -y "$@"
  ok "インストール完了: $*"
}

cmd_remove() {
  require_root
  [[ ${#@} -gt 0 ]] || { err "パッケージ名を指定してください。"; exit 1; }
  inf "削除中: $*"
  _log "remove: $*"
  apt-get remove -y "$@"
  ok "削除完了: $*"
}

cmd_update() {
  require_root
  inf "パッケージリスト更新中..."
  _log "update"
  apt-get update
  ok "更新完了"
}

cmd_upgrade() {
  require_root
  inf "パッケージアップグレード中..."
  _log "upgrade"
  DEBIAN_FRONTEND=noninteractive apt-get upgrade -y
  ok "アップグレード完了"
}

cmd_search() {
  [[ ${#@} -gt 0 ]] || { err "検索キーワードを指定してください。"; exit 1; }
  inf "検索中: $*"
  apt-cache search "$@" | sort
}

cmd_info() {
  [[ ${#@} -gt 0 ]] || { err "パッケージ名を指定してください。"; exit 1; }
  apt-cache show "$1"
}

cmd_list() {
  inf "インストール済みパッケージ:"
  dpkg -l | grep "^ii" | awk '{printf "  %-30s %s\n", $2, $3}'
}

cmd_clean() {
  require_root
  inf "キャッシュクリーンアップ中..."
  apt-get clean
  apt-get autoremove -y
  ok "クリーンアップ完了"
}

cmd_check() {
  inf "システム整合性チェック中..."
  dpkg --audit
  apt-get check
  ok "チェック完了"
}

cmd_history() {
  if [[ -f "${LOG_FILE}" ]]; then
    cat "${LOG_FILE}"
  else
    inf "履歴なし"
  fi
}

cmd_version() {
  echo -e "${BOLD}cos-pkg${RESET} version ${VERSION} — ClaudeOS Package Manager"
  echo "Backend: $(apt-get --version | head -1)"
}

# ── メイン ─────────────────────────────────────────────────────────────────
case "${1:-help}" in
  install)  shift; cmd_install  "$@" ;;
  remove)   shift; cmd_remove   "$@" ;;
  update)         cmd_update        ;;
  upgrade)        cmd_upgrade       ;;
  search)   shift; cmd_search   "$@" ;;
  info)     shift; cmd_info     "$@" ;;
  list)           cmd_list          ;;
  clean)          cmd_clean         ;;
  check)          cmd_check         ;;
  history)        cmd_history       ;;
  version)        cmd_version       ;;
  help|--help|-h) usage             ;;
  *) err "不明なコマンド: $1"; usage; exit 1 ;;
esac
PKG_EOF

  chmod +x "${CHROOT_DIR}/usr/local/bin/cos-pkg"
  log "cos-pkg パッケージマネージャを作成"
}

# ── Step 4: SquashFS ライブイメージ作成 ──────────────────────────────────────
create_squashfs() {
  banner "Step 4: SquashFS ライブイメージ作成"
  info "squashfs 圧縮中 (時間がかかります)..."
  mksquashfs "${CHROOT_DIR}" "${ISO_DIR}/live/filesystem.squashfs" \
    -comp xz -e boot 2>&1 | tail -3
  log "squashfs 作成完了: $(du -sh "${ISO_DIR}/live/filesystem.squashfs" | cut -f1)"
}

# ── Step 5: カーネル & initrd コピー ─────────────────────────────────────────
copy_kernel() {
  banner "Step 5: カーネル・initrd コピー"
  local vmlinuz initrd

  vmlinuz=$(ls "${CHROOT_DIR}/boot/vmlinuz-"* 2>/dev/null | sort -V | tail -1 || true)
  initrd=$(ls  "${CHROOT_DIR}/boot/initrd.img-"* 2>/dev/null | sort -V | tail -1 || true)

  if [[ -z "$vmlinuz" ]]; then
    warn "カーネルが見つかりません。ダミーファイルを作成します。"
    echo "dummy kernel" > "${ISO_DIR}/boot/vmlinuz"
    echo "dummy initrd" > "${ISO_DIR}/boot/initrd"
  else
    cp "$vmlinuz" "${ISO_DIR}/boot/vmlinuz"
    cp "$initrd"  "${ISO_DIR}/boot/initrd"
    log "カーネル: $(basename "$vmlinuz")"
    log "initrd:   $(basename "$initrd")"
  fi
}

# ── Step 6: GRUB 設定 ─────────────────────────────────────────────────────────
configure_grub() {
  banner "Step 6: GRUB ブートローダ設定"

  cat > "${ISO_DIR}/boot/grub/grub.cfg" << 'GRUB_EOF'
# ─────────────────────────────────────────
#  ClaudeOS GRUB Configuration
# ─────────────────────────────────────────
set default=0
set timeout=5
set timeout_style=menu

insmod all_video
insmod gfxterm
terminal_output gfxterm

set menu_color_normal=white/black
set menu_color_highlight=black/cyan

menuentry "ClaudeOS 1.0 'Aurora' — Live" --class claudeos --class gnu-linux {
  linux /boot/vmlinuz boot=live quiet splash
  initrd /boot/initrd
}

menuentry "ClaudeOS 1.0 'Aurora' — Safe Mode" --class claudeos {
  linux /boot/vmlinuz boot=live nomodeset
  initrd /boot/initrd
}

menuentry "Memory Test (memtest86+)" --class memtest {
  linux16 /boot/memtest86+.bin
}

menuentry "Boot from Hard Disk" --class hd {
  chainloader (hd0)+1
}
GRUB_EOF

  log "GRUB 設定完了"
}

# ── Step 7: ISO メタデータ ────────────────────────────────────────────────────
create_metadata() {
  banner "Step 7: ISO メタデータ作成"
  mkdir -p "${ISO_DIR}/.claudeos"

  # ビルド情報
  cat > "${ISO_DIR}/.claudeos/build-info.txt" << EOF
DISTRO_NAME=${DISTRO_NAME}
DISTRO_VERSION=${DISTRO_VERSION}
DISTRO_CODENAME=${DISTRO_CODENAME}
BUILD_DATE=$(date -u '+%Y-%m-%d %H:%M:%S UTC')
BUILD_HOST=$(uname -n)
BASE_SUITE=${SUITE}
ARCH=${ARCH}
KERNEL=$(ls "${CHROOT_DIR}/boot/vmlinuz-"* 2>/dev/null | sort -V | tail -1 | xargs basename 2>/dev/null || echo "N/A")
PACKAGES=$(chroot "${CHROOT_DIR}" dpkg -l 2>/dev/null | grep "^ii" | wc -l || echo "N/A")
EOF

  # README
  cat > "${ISO_DIR}/README.txt" << 'README_EOF'
ClaudeOS 1.0 "Aurora"
=====================

A minimal Linux distribution built from scratch using shell scripts,
based on Ubuntu Noble (24.04) with the apt/dpkg package manager.

Default Credentials:
  User:  claude  / Password: claude
  Root:  root    / Password: claudeos

Package Manager:
  cos-pkg install <package>   — Install packages
  cos-pkg update              — Update package list
  cos-pkg search <keyword>    — Search packages

Built with debootstrap + mksquashfs + xorriso
README_EOF

  log "メタデータ作成完了"
  cat "${ISO_DIR}/.claudeos/build-info.txt"
}

# ── Step 8: ISO イメージ作成 ──────────────────────────────────────────────────
create_iso() {
  banner "Step 8: ISO イメージ作成"
  info "xorriso で ISO を生成中..."

  xorriso -as mkisofs \
    -iso-level 3 \
    -full-iso9660-filenames \
    -volid "CLAUDEOS_1_0" \
    -output "${OUTPUT_ISO}" \
    -eltorito-boot boot/grub/bios.img \
    -no-emul-boot \
    -boot-load-size 4 \
    -boot-info-table \
    --eltorito-catalog boot/grub/boot.cat \
    --grub2-boot-info \
    --grub2-mbr /usr/lib/grub/i386-pc/boot_hybrid.img \
    -eltorito-alt-boot \
    -e EFI/efiboot.img \
    -no-emul-boot \
    -append_partition 2 0xef "${ISO_DIR}/EFI/efiboot.img" \
    -graft-points \
      "${ISO_DIR}" \
      /boot/grub/bios.img="${ISO_DIR}/boot/grub/bios.img" \
    2>&1 | grep -v "^xorriso" | grep -v "^$" || true

  log "ISO 作成完了: ${OUTPUT_ISO}"
  log "サイズ: $(du -sh "${OUTPUT_ISO}" | cut -f1)"
}

# ── Step 8 代替: GRUB を手動で埋め込んでシンプル ISO 作成 ────────────────────
create_iso_simple() {
  banner "Step 8: ISO イメージ作成 (シンプルモード)"

  # BIOS GRUB ブートイメージを準備
  info "GRUB BIOS ブートイメージを準備中..."
  mkdir -p "${ISO_DIR}/boot/grub/i386-pc"

  # GRUB 必要モジュールをコピー
  if [[ -d /usr/lib/grub/i386-pc ]]; then
    cp /usr/lib/grub/i386-pc/*.mod "${ISO_DIR}/boot/grub/i386-pc/" 2>/dev/null || true
    cp /usr/lib/grub/i386-pc/*.lst "${ISO_DIR}/boot/grub/i386-pc/" 2>/dev/null || true
  fi

  # grub-mkstandalone で standalone BIOS イメージ作成
  info "GRUB standalone イメージ生成中..."
  grub-mkstandalone \
    --format=i386-pc \
    --output="${ISO_DIR}/boot/grub/core.img" \
    --install-modules="linux normal iso9660 biosdisk memdisk search tar ls" \
    --modules="linux normal iso9660 biosdisk search" \
    "boot/grub/grub.cfg=${ISO_DIR}/boot/grub/grub.cfg" \
    2>/dev/null || warn "grub-mkstandalone に失敗 (スキップ)"

  # xorriso でシンプルな ISO 作成
  info "xorriso で ISO 生成中..."
  xorriso -as mkisofs \
    -iso-level 3 \
    -full-iso9660-filenames \
    -volid "CLAUDEOS_1_0" \
    -output "${OUTPUT_ISO}" \
    "${ISO_DIR}" \
    2>&1 | grep -v "^$" | tail -10

  log "ISO 作成完了: ${OUTPUT_ISO}"
}

# ── メイン処理 ────────────────────────────────────────────────────────────────
main() {
  clear
  echo -e "${BOLD}${CYAN}"
  cat << 'LOGO'
  ██████╗██╗      █████╗ ██╗   ██╗██████╗ ███████╗ ██████╗ ███████╗
 ██╔════╝██║     ██╔══██╗██║   ██║██╔══██╗██╔════╝██╔═══██╗██╔════╝
 ██║     ██║     ███████║██║   ██║██║  ██║█████╗  ██║   ██║███████╗
 ██║     ██║     ██╔══██║██║   ██║██║  ██║██╔══╝  ██║   ██║╚════██║
 ╚██████╗███████╗██║  ██║╚██████╔╝██████╔╝███████╗╚██████╔╝███████║
  ╚═════╝╚══════╝╚═╝  ╚═╝ ╚═════╝ ╚═════╝ ╚══════╝ ╚═════╝ ╚══════╝
LOGO
  echo -e "${RESET}${BOLD}  ClaudeOS Builder v${DISTRO_VERSION} — 独自 Linux ディストリビューション構築${RESET}\n"

  local start_time=$SECONDS

  check_prerequisites
  prepare_dirs
  build_base
  configure_chroot
  create_pkg_manager
  create_squashfs
  copy_kernel
  configure_grub
  create_metadata
  create_iso_simple

  local elapsed=$((SECONDS - start_time))
  banner "🎉 ビルド完了!"
  echo -e "${BOLD}  ディストリビューション: ${GREEN}${DISTRO_NAME} ${DISTRO_VERSION} '${DISTRO_CODENAME}'${RESET}"
  echo -e "${BOLD}  ISO ファイル:   ${GREEN}${OUTPUT_ISO}${RESET}"
  echo -e "${BOLD}  サイズ:         ${GREEN}$(du -sh "${OUTPUT_ISO}" 2>/dev/null | cut -f1 || echo 'N/A')${RESET}"
  echo -e "${BOLD}  ビルド時間:     ${GREEN}${elapsed}秒${RESET}"
  echo -e "${BOLD}  インストール済パッケージ数: ${GREEN}$(chroot "${CHROOT_DIR}" dpkg -l 2>/dev/null | grep -c "^ii" || echo 'N/A')${RESET}"
  echo ""
  echo -e "  ${CYAN}仮想マシン (QEMU/VirtualBox) で起動できます:${RESET}"
  echo -e "  ${YELLOW}  qemu-system-x86_64 -cdrom ${OUTPUT_ISO} -m 2G${RESET}"
  echo ""
}

main "$@"
