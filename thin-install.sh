#!/usr/bin/env bash
# Thin client installer: Arch Linux + LXQt + LightDM + PipeWire + Omnissa Horizon client
# Target: HP t610 (AMD GPU). Run as root on a fresh Arch install.
#
# Usage:
#   ./install-thinclient.sh install        # packages, Horizon client, thinuser, themes
#   ./install-thinclient.sh cleanup        # remove build tools (run after testing the client)
#   ./install-thinclient.sh autologin      # enable autologin + autostart Horizon
#   ./install-thinclient.sh autologin-off  # undo autologin + autostart
#   ./install-thinclient.sh check-video    # show GPU, driver and firmware messages
#   ./install-thinclient.sh bootloader     # reinstall GRUB (UEFI, --removable)

set -euo pipefail

# ---------- Settings: edit these ----------
THIN_USER="thinuser"
BUILD_USER="builder"
AUR_PKG="omnissa-horizon-client"         # https://aur.archlinux.org/packages/omnissa-horizon-client
SERVER_URL="vdi.yourcompany.com"
PKG_SAVE_DIR="/root/packages"
# Extra applications from the official repos (edit this list to add or remove apps).
# firefox / chromium = browsers (Chromium is the open-source base of Google Chrome)
# abiword            = light word processor that opens and saves .docx
# fonts + dictionary = so documents and web pages look right
# For the full LibreOffice suite use "libreoffice-fresh" (about 1 GB, slow on a t610).
APPS=(firefox chromium abiword ttf-liberation ttf-dejavu hunspell-en_us)
# ------------------------------------------

log()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
die()  { printf '\n\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }
warn() { printf '\n\033[1;33mWARNING: %s\033[0m\n' "$*"; }
need_root() { [[ $EUID -eq 0 ]] || die "Run this script as root."; }

# Refuse settings that could make rm -rf or userdel -r hit the wrong place
check_settings() {
  local v
  for v in THIN_USER BUILD_USER AUR_PKG PKG_SAVE_DIR; do
    [[ -n "${!v}" ]] || die "Setting $v is empty."
  done
  [[ "$BUILD_USER" != "root" && "$THIN_USER" != "root" ]] \
    || die "THIN_USER and BUILD_USER must not be root."
  [[ "$BUILD_USER" != "$THIN_USER" ]] \
    || die "BUILD_USER and THIN_USER must be different (cleanup deletes BUILD_USER's home)."
  [[ "$AUR_PKG" =~ ^[A-Za-z0-9@._+-]+$ ]] \
    || die "AUR_PKG contains unexpected characters."
  [[ "$PKG_SAVE_DIR" == /?* ]] \
    || die "PKG_SAVE_DIR must be an absolute path other than /."
}

detect_client() {
  for c in horizon-client vmware-view; do
    command -v "$c" >/dev/null 2>&1 && { echo "$c"; return; }
  done
  die "Horizon client command not found. Is the package installed?"
}

install_packages() {
  log "Installing system packages"
  pacman -Syu --noconfirm
  # NOTE: the lxqt group installs all members with --noconfirm
  pacman -S --needed --noconfirm \
    xorg-server mesa linux-firmware xf86-video-ati \
    lxqt openbox lightdm lightdm-gtk-greeter \
    networkmanager network-manager-applet \
    pipewire pipewire-pulse pipewire-alsa wireplumber alsa-utils pavucontrol-qt \
    kvantum papirus-icon-theme \
    dosfstools smartmontools hdparm pciutils \
    base-devel git

  # Browsers and word processor. A wrong name here must not break the base install.
  if ((${#APPS[@]})); then
    log "Installing applications: ${APPS[*]}"
    pacman -S --needed --noconfirm "${APPS[@]}" \
      || warn "Some applications failed to install. Check the names in APPS and run: pacman -S --needed <name>"
  fi

  # Radeon HD 6320 (t610) firmware is in a separate package on current Arch, if it exists
  pacman -S --needed --noconfirm linux-firmware-radeon 2>/dev/null || true

  # Load the radeon driver early (early KMS) by adding it to MODULES
  if ! grep -q '^MODULES=(.*radeon.*)' /etc/mkinitcpio.conf; then
    sed -i 's/^MODULES=(/MODULES=(radeon /' /etc/mkinitcpio.conf
  fi
  grep -q '^MODULES=(.*radeon.*)' /etc/mkinitcpio.conf \
    || warn "Could not add radeon to MODULES in /etc/mkinitcpio.conf. Add it by hand."

  # Rebuild the ramdisk so the GPU driver and firmware are picked up
  mkinitcpio -P

  # LightDM replaces SDDM: only one display manager can own display-manager.service
  systemctl disable sddm 2>/dev/null || true
  rm -f /etc/sddm.conf.d/autologin.conf
  if pacman -Qi sddm >/dev/null 2>&1; then
    pacman -Rns --noconfirm sddm \
      || warn "Could not remove sddm (another package needs it). It is disabled, which is enough."
  fi

  systemctl enable NetworkManager lightdm
  systemctl --global enable pipewire.socket pipewire-pulse.socket wireplumber.service
}

build_client() {
  log "Building $AUR_PKG as unprivileged user '$BUILD_USER'"
  id "$BUILD_USER" >/dev/null 2>&1 || useradd -m "$BUILD_USER"

  local dir="/home/${BUILD_USER:?}/${AUR_PKG:?}"
  # Only ever delete a folder inside the build user's own home
  [[ "$dir" == "/home/$BUILD_USER/"?* ]] || die "Refusing to delete unexpected path: $dir"
  rm -rf -- "$dir"
  su - "$BUILD_USER" -c "git clone https://aur.archlinux.org/$AUR_PKG.git" \
    || die "git clone failed. Check the AUR_PKG name and your network connection."

  # The AUR creates an EMPTY repository for any name, so a clone can "succeed" for a package that does not exist
  [[ -f "$dir/PKGBUILD" ]] || die "No PKGBUILD in $dir. The AUR package '$AUR_PKG' does not exist under that name. Run: curl -s 'https://aur.archlinux.org/rpc/v5/search/omnissa?by=name'"

  log "Source URLs in the PKGBUILD (should be vmware.com or omnissa.com):"
  grep -E '^\s*(source|_url|url)' "$dir/PKGBUILD" || true
  read -r -p "Do the URLs look right? [y/N] " ok
  [[ "$ok" =~ ^[Yy]$ ]] || die "Aborted by user."

  log "Installing known build dependencies"
  pacman -S --needed --noconfirm resvg oxipng

  log "Installing any other dependencies listed in the PKGBUILD"
  local srcinfo pkgnames d
  local -a found=() missing=()
  srcinfo=$(su - "$BUILD_USER" -c "cd $AUR_PKG && makepkg --printsrcinfo")
  # Names this PKGBUILD builds itself (split packages can depend on each other)
  pkgnames=$(awk '/^[[:space:]]*pkgname = /{print $3}' <<<"$srcinfo")
  while read -r d; do
    [[ -z "$d" ]] && continue
    grep -qx -- "$d" <<<"$pkgnames" && continue     # built by this PKGBUILD, not in the repos
    if pacman -Sp "$d" >/dev/null 2>&1; then found+=("$d"); else missing+=("$d"); fi
  done < <(awk '/^[[:space:]]*(make)?depends = /{print $3}' <<<"$srcinfo" | sed 's/[<>=].*//' | sort -u)

  if ((${#found[@]})); then
    pacman -S --needed --noconfirm --asdeps "${found[@]}"
  fi
  if ((${#missing[@]})); then
    printf '\n\033[1;33mWARNING: not in the official repos (AUR only?): %s\033[0m\n' "${missing[*]}"
    echo "Build them first the same way, or install them, then re-run. Continuing; makepkg will fail if they are really needed."
  fi

  log "Compiling"
  su - "$BUILD_USER" -c "cd $AUR_PKG && makepkg --noconfirm"

  log "Saving and installing the package"
  mkdir -p "$PKG_SAVE_DIR"
  cp "$dir"/*.pkg.tar.zst "$PKG_SAVE_DIR"/
  pacman -U --noconfirm "$dir"/*.pkg.tar.zst
}

configure_system() {
  log "Windows-like defaults for new users"
  mkdir -p /etc/skel/.config/lxqt
  cat > /etc/skel/.config/lxqt/lxqt.conf <<'EOF'
[General]
icon_theme=Papirus

[Qt]
style=kvantum
EOF

  log "LightDM defaults (greeter and session)"
  mkdir -p /etc/lightdm/lightdm.conf.d
  cat > /etc/lightdm/lightdm.conf.d/10-thinclient.conf <<'EOF'
[Seat:*]
greeter-session=lightdm-gtk-greeter
user-session=lxqt
EOF

  log "Creating user '$THIN_USER' (no sudo)"
  if ! id "$THIN_USER" >/dev/null 2>&1; then
    useradd -m -s /bin/bash "$THIN_USER"
    echo "Set the password for $THIN_USER:"
    passwd "$THIN_USER"
  fi
}

do_install() {
  install_packages
  build_client
  configure_system
  local client; client=$(detect_client)
  log "Install finished."
  cat <<EOF

Next steps:
  1. reboot
  2. Log in as $THIN_USER, session "LXQt Desktop"
  3. Test in a terminal:   $client --serverURL=$SERVER_URL --fullscreen
  4. Test sound:           wpctl status
     Apps (Firefox, Chromium, AbiWord) are in the LXQt start menu.
  5. When all works:       ./install-thinclient.sh cleanup
  6. Optional:             ./install-thinclient.sh autologin
EOF
}

do_cleanup() {
  log "Removing build user and build tools"
  pacman -Qi "$AUR_PKG" >/dev/null 2>&1 || die "$AUR_PKG is not installed. Not cleaning up."

  # Delete the build user only if its home is a normal folder under /home
  if id "$BUILD_USER" >/dev/null 2>&1; then
    local build_home
    build_home=$(getent passwd "$BUILD_USER" | cut -d: -f6)
    [[ "$build_home" == "/home/$BUILD_USER" ]] \
      || die "Home of $BUILD_USER is '$build_home', not /home/$BUILD_USER. Not deleting it."
    userdel -r "$BUILD_USER"
  fi

  # Remove one by one: pacman refuses packages still required by others, which is what we want
  for p in git $(pacman -Sgq base-devel) resvg oxipng; do
    pacman -Qi "$p" >/dev/null 2>&1 && pacman -Rns --noconfirm "$p" 2>/dev/null || true
  done

  log "Removing orphans"
  local orphans
  while orphans=$(pacman -Qdtq) && [[ -n "$orphans" ]]; do
    # shellcheck disable=SC2086
    pacman -Rns --noconfirm $orphans || break
  done

  pacman -Scc --noconfirm
  detect_client >/dev/null
  log "Cleanup done. Package copy kept in $PKG_SAVE_DIR"
  echo "To rebuild later: pacman -S --needed base-devel git, then re-run 'install'."
}

do_autologin() {
  local client; client=$(detect_client)
  log "Enabling autologin for $THIN_USER and autostart of $client"
  id "$THIN_USER" >/dev/null 2>&1 || die "User $THIN_USER does not exist. Run 'install' first."
  # LightDM's PAM autologin rule only accepts users in the "autologin" group
  groupadd -rf autologin
  usermod -aG autologin "$THIN_USER"
  mkdir -p /etc/lightdm/lightdm.conf.d /etc/xdg/autostart
  cat > /etc/lightdm/lightdm.conf.d/20-autologin.conf <<EOF
[Seat:*]
autologin-user=$THIN_USER
autologin-user-timeout=0
autologin-session=lxqt
EOF
  cat > /etc/xdg/autostart/horizon.desktop <<EOF
[Desktop Entry]
Type=Application
Name=Horizon
Exec=$client --serverURL=$SERVER_URL --fullscreen
EOF
  echo "Done. Reboot to test."
}

do_autologin_off() {
  log "Disabling autologin and autostart"
  rm -f /etc/lightdm/lightdm.conf.d/20-autologin.conf /etc/xdg/autostart/horizon.desktop
  gpasswd -d "$THIN_USER" autologin 2>/dev/null || true
  echo "Done."
}

do_check_video() {
  log "Video hardware and driver in use"
  lspci -k | grep -A3 -E 'VGA|Display' || true
  echo
  log "Kernel command line (nomodeset means the GPU is switched off)"
  cat /proc/cmdline
  echo
  log "Radeon firmware files for the Wrestler chip (HD 6320) should exist"
  ls /usr/lib/firmware/radeon/ 2>/dev/null | grep -iE 'palm|sumo' || echo "WARNING: PALM/SUMO firmware not found"
  echo
  log "Graphics firmware or driver messages"
  dmesg | grep -iE 'radeon|amdgpu|firmware' | tail -20 || true
}

do_bootloader() {
  log "Refreshing the GRUB bootloader (UEFI, removable path so the BIOS always finds it)"
  [[ -d /sys/firmware/efi ]] || die "Not booted in UEFI mode. Not changing the bootloader."
  mountpoint -q /boot || die "/boot is not mounted. Mount the EFI partition first."
  pacman -S --needed --noconfirm grub efibootmgr dosfstools
  grub-install --target=x86_64-efi --efi-directory=/boot --removable --no-nvram
  grub-mkconfig -o /boot/grub/grub.cfg
  ls /boot/EFI/BOOT/
  echo "Done."
}

need_root
check_settings
case "${1:-}" in
  check-video)    do_check_video ;;
  bootloader)     do_bootloader ;;
  install)        do_install ;;
  cleanup)        do_cleanup ;;
  autologin)      do_autologin ;;
  autologin-off)  do_autologin_off ;;
  *) echo "Usage: $0 {install|cleanup|autologin|autologin-off|check-video|bootloader}"; exit 1 ;;
esac
