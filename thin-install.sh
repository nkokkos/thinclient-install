#!/usr/bin/env bash
# Thin client installer: Arch Linux + XFCE + LXQt + LightDM + PipeWire + Omnissa Horizon client
# Target: HP t610 (AMD GPU). Run as root on a fresh Arch install.
#
# For HP t610 the Xorg GPU mode is set to "modesetting" during install.
#
# Usage:
#   ./install-thinclient.sh install        # packages, Horizon client, thinuser, themes
#   ./install-thinclient.sh greek          # add Greek locale, keyboard (Alt+Shift), spell check (also done by install)
#   ./install-thinclient.sh save-prefs     # copy Horizon client settings (Blast codecs) to all new users
#   ./install-thinclient.sh cleanup        # remove build tools (run after testing the client)
#   ./install-thinclient.sh autologin      # enable autologin + autostart Horizon
#   ./install-thinclient.sh autologin-off  # undo autologin + autostart
#   ./install-thinclient.sh check-video    # show GPU, driver, decoding and firmware messages
#   ./install-thinclient.sh bootloader     # reinstall GRUB (UEFI, --removable)
#   ./install-thinclient.sh debug-gui      # save GPU/Xorg/kernel/Horizon logs to /root/gui-debug.txt
#   ./install-thinclient.sh gpu-mode MODE  # MODE: glamor | exa | none | modesetting | reset
#
# BLANK / BLACK REMOTE SCREEN (Horizon connects but the desktop is empty):
#   1. In the client open Settings > Blast and untick H.264 and HEVC decoding.
#   2. Close the client, then run:  ./install-thinclient.sh save-prefs
#   3. If still blank, test in a terminal inside the LXQt session:
#        LIBGL_ALWAYS_SOFTWARE=1 horizon-client --serverURL=YOUR_SERVER

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
APPS=(ttf-liberation ttf-dejavu)
# Both XFCE and LXQt are installed. Which one starts by default? "xfce" or "lxqt".
# The other one stays available in the session menu on the login screen.
DEFAULT_SESSION="xfce"
# ------------------------------------------

PLACEHOLDER_SERVER="vdi.yourcompany.com"

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
  [[ "$DEFAULT_SESSION" == "xfce" || "$DEFAULT_SESSION" == "lxqt" ]] \
    || die "DEFAULT_SESSION must be \"xfce\" or \"lxqt\"."
}

# Checks that must pass before the long install starts
preflight() {
  [[ -f /etc/arch-release ]] || die "This script is for Arch Linux."
  command -v pacman >/dev/null 2>&1 || die "pacman not found."
  log "Checking the network"
  if command -v curl >/dev/null 2>&1; then
    curl -fsS --max-time 15 -o /dev/null https://aur.archlinux.org \
      || die "Cannot reach aur.archlinux.org. Check the network (nmcli, ping) and try again."
  else
    ping -c1 -W5 archlinux.org >/dev/null 2>&1 \
      || die "No network. Check the connection and try again."
  fi
  if [[ "$SERVER_URL" == "$PLACEHOLDER_SERVER" ]]; then
    warn "SERVER_URL is still the placeholder ($PLACEHOLDER_SERVER). Edit it at the top of this script before running 'autologin'."
  fi
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
  # xf86-input-libinput and xorg-xauth are needed for keyboard, mouse and LightDM to work in X
  pacman -S --needed --noconfirm \
    xorg-server xorg-xauth xf86-input-libinput mesa linux-firmware xorg-xrandr \
    lxqt openbox xfce4 xfce4-goodies lightdm lightdm-gtk-greeter \
    networkmanager network-manager-applet \
    pipewire pipewire-pulse pipewire-alsa wireplumber alsa-utils pavucontrol-qt \
    kvantum papirus-icon-theme \
    dosfstools smartmontools hdparm pciutils \
    base-devel git curl nss-mdns \
    gvfs udisks2 thunar-volman ntfs-3g exfatprogs usbutils

  # Video decoding and diagnostic tools. Optional: a wrong name must not break the base install.
  log "Installing optional video diagnostic tools"
  local p
  for p in libva-utils mesa-utils vdpauinfo libva-mesa-driver mesa-vdpau; do
    pacman -S --needed --noconfirm "$p" >/dev/null 2>&1 \
      || warn "Optional package $p was not installed (not needed to run the client)."
  done

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
  systemctl mask upower.service 2>/dev/null || true
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

  # XFCE: turn the window compositor off for new users (lighter on a t610, and avoids
  # blank-window problems with remote desktop clients)
  mkdir -p /etc/skel/.config/xfce4/xfconf/xfce-perchannel-xml
  cat > /etc/skel/.config/xfce4/xfconf/xfce-perchannel-xml/xfwm4.xml <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<channel name="xfwm4" version="1.0">
  <property name="general" type="empty">
    <property name="use_compositing" type="bool" value="false"/>
  </property>
</channel>
EOF

  log "LightDM defaults (greeter and session)"
  mkdir -p /etc/lightdm/lightdm.conf.d
  [[ -f "/usr/share/xsessions/$DEFAULT_SESSION.desktop" ]] \
    || die "Session file /usr/share/xsessions/$DEFAULT_SESSION.desktop not found. Is the desktop installed?"
  cat > /etc/lightdm/lightdm.conf.d/10-thinclient.conf <<EOF
[Seat:*]
greeter-session=lightdm-gtk-greeter
user-session=$DEFAULT_SESSION
EOF

  # HP t610: use the modesetting Xorg driver (kept if you already chose a mode with gpu-mode)
  if [[ ! -f /etc/X11/xorg.conf.d/20-gpu.conf ]]; then
    log "Setting Xorg GPU mode to modesetting (HP t610)"
    mkdir -p /etc/X11/xorg.conf.d
    cat > /etc/X11/xorg.conf.d/20-gpu.conf <<'EOF'
Section "Device"
    Identifier "GPU"
    Driver "modesetting"
EndSection
EOF
  fi

  log "Creating user '$THIN_USER' (no sudo)"
  if ! id "$THIN_USER" >/dev/null 2>&1; then
    useradd -m -s /bin/bash "$THIN_USER"
    echo "Set the password for $THIN_USER:"
    passwd "$THIN_USER"
  fi
}

# Greek support: locale, keyboard layout, spell check and Firefox language pack.
# The system language stays English. Greek is added for typing (Alt+Shift switches
# between US and Greek), spell checking, and as a language you can pick at login.
# Greek fonts are already covered by ttf-dejavu and ttf-liberation.
configure_greek() {
  log "Adding Greek language support"

  # Locales: make sure en_US and el_GR are enabled, then generate them
  local loc
  for loc in "en_US.UTF-8 UTF-8" "el_GR.UTF-8 UTF-8"; do
    sed -i "s/^#\(${loc}\)/\1/" /etc/locale.gen
    grep -qxF "$loc" /etc/locale.gen || echo "$loc" >> /etc/locale.gen
  done
  locale-gen
  [[ -f /etc/locale.conf ]] || echo 'LANG=en_US.UTF-8' > /etc/locale.conf

  # Spell check (AbiWord, Firefox) and Firefox Greek language pack. Optional.
  local p
  for p in hunspell-el firefox-i18n-el; do
    pacman -S --needed --noconfirm "$p" >/dev/null 2>&1 \
      || warn "Optional package $p was not installed."
  done

  # Keyboard: US + Greek, Alt+Shift to switch. Do not overwrite an existing keyboard config.
  local kb=/etc/X11/xorg.conf.d/00-keyboard.conf
  if [[ -f "$kb" ]]; then
    warn "$kb already exists, not changing it. To add Greek, set XkbLayout to \"us,gr\" and XkbOptions to \"grp:alt_shift_toggle\" in that file."
  else
    mkdir -p /etc/X11/xorg.conf.d
    cat > "$kb" <<'EOF'
Section "InputClass"
    Identifier "keyboard-layouts"
    MatchIsKeyboard "on"
    Option "XkbLayout" "us,gr"
    Option "XkbOptions" "grp:alt_shift_toggle"
EndSection
EOF
  fi
  echo "Greek added. Alt+Shift switches the keyboard between US and Greek after the next login."
  echo "To use Greek as the display language, set in /etc/locale.conf:  LANG=el_GR.UTF-8"
}

do_install() {
  preflight
  install_packages
  build_client
  configure_system
  configure_greek
  local client; client=$(detect_client)
  log "Install finished."
  cat <<EOF

Next steps:
  1. reboot
  2. Log in as $THIN_USER. Default session: $DEFAULT_SESSION (pick the other one, XFCE or LXQt, in the session menu on the login screen)
  3. Open a terminal and test:   $client --serverURL=$SERVER_URL --fullscreen
  4. If the remote desktop is BLANK or BLACK:
       a. In the client: Settings > Blast, untick H.264 and HEVC decoding
       b. Close the client and run (as root):  ./install-thinclient.sh save-prefs
       c. Still blank? Try:  LIBGL_ALWAYS_SOFTWARE=1 $client --serverURL=$SERVER_URL
       d. Then run:  ./install-thinclient.sh debug-gui   and read /root/gui-debug.txt
  5. Greek: Alt+Shift switches the keyboard between US and Greek.
     For the remote Windows desktop, the Greek keyboard layout must also be added inside Windows.
     Test sound:           wpctl status
     Apps (Firefox, Chromium, AbiWord) are in the LXQt start menu.
  6. When all works:       ./install-thinclient.sh cleanup
  7. Optional:             ./install-thinclient.sh autologin
EOF
}

# Copy the Horizon client settings (for example the Blast codec choice) so new users get them too
do_save_prefs() {
  local src="${1:-/home/$THIN_USER/.vmware/view-preferences}"
  local dst_skel=/etc/skel/.vmware/view-preferences
  local dst_user="/home/$THIN_USER/.vmware/view-preferences"
  [[ -f "$src" ]] || die "No settings file at $src. Log in as $THIN_USER, start the client, change Settings > Blast, close the client, then run this again."
  log "Saving Horizon client settings from $src"
  install -D -m 644 "$src" "$dst_skel"
  if id "$THIN_USER" >/dev/null 2>&1 && ! [[ "$src" -ef "$dst_user" ]]; then
    install -D -o "$THIN_USER" -g "$THIN_USER" -m 644 "$src" "$dst_user"
  fi
  echo "Saved to $dst_skel (used for every new user)."
  echo "Settings in the file:"
  cat "$src"
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
  [[ "$SERVER_URL" != "$PLACEHOLDER_SERVER" ]] \
    || die "SERVER_URL is still the placeholder. Edit it at the top of this script first."
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
autologin-session=$DEFAULT_SESSION
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
  echo
  log "Video decoding support (H.264 missing = disable H.264/HEVC in the Horizon Blast settings)"
  if command -v vainfo >/dev/null 2>&1; then
    vainfo 2>&1 | head -20 || true
  else
    echo "vainfo is not installed (package libva-utils)."
  fi
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

# Collect everything needed to diagnose black screen / flicker problems into one file
do_debug_gui() {
  local out=/root/gui-debug.txt
  log "Collecting GUI/GPU debug information into $out"
  (
    set +e   # keep going when a single check fails
    echo "### date / kernel"; date; uname -r
    echo; echo "### kernel command line"; cat /proc/cmdline
    echo; echo "### GPU and driver in use"; lspci -k | grep -A3 -E 'VGA|Display'
    echo; echo "### graphics packages"; pacman -Q xorg-server mesa xf86-video-ati linux-firmware linux-firmware-radeon lightdm 2>&1
    echo; echo "### video decoding (vainfo)"; vainfo 2>&1 | head -30
    echo; echo "### Xorg config files"; ls -l /etc/X11/xorg.conf.d/ 2>&1; cat /etc/X11/xorg.conf.d/*.conf 2>/dev/null
    echo; echo "### Xorg errors and warnings"
    grep -hE '\(EE\)|\(WW\)' /var/log/Xorg.0.log /var/log/lightdm/x-0.log \
      "/home/$THIN_USER/.local/share/xorg/Xorg.0.log" 2>/dev/null | sort -u | tail -60
    echo; echo "### Kernel GPU messages (lockup, ring, fence = GPU hang)"
    dmesg | grep -iE 'radeon|drm|gpu|ring|lockup|fence|hung' | tail -60
    echo; echo "### Errors this boot"; journalctl -b -p err --no-pager | tail -40
    echo; echo "### Horizon client settings"; cat "/home/$THIN_USER/.vmware/view-preferences" 2>&1
    echo; echo "### Horizon client log (errors, Blast, codec)"
    grep -hiE 'error|fail|blast|codec|h264|hevc' /tmp/vmware-"$THIN_USER"/vmware-view-*.log 2>/dev/null | tail -40
    echo; echo "### Window manager / compositor processes"
    ps -eo comm | grep -iE 'picom|compton|kwin|openbox|xcompmgr|lxqt-session|pcmanfm' | sort -u
    echo; echo "### Memory"; free -h
  ) > "$out" 2>&1
  echo "Saved. Read it with:  less $out"
}

# Switch the Xorg graphics driver mode to find a stable setting
do_gpu_mode() {
  local mode="${1:-}"
  local conf=/etc/X11/xorg.conf.d/20-gpu.conf
  mkdir -p /etc/X11/xorg.conf.d
  case "$mode" in
    glamor|exa|none)
      # The radeon Xorg driver is only needed for these modes, so install it on demand
      pacman -S --needed --noconfirm xf86-video-ati \
        || die "Could not install xf86-video-ati."
      cat > "$conf" <<EOF
Section "Device"
    Identifier "Radeon"
    Driver "radeon"
    Option "AccelMethod" "$mode"
EndSection
EOF
      ;;
    modesetting)
      cat > "$conf" <<'EOF'
Section "Device"
    Identifier "GPU"
    Driver "modesetting"
EndSection
EOF
      ;;
    reset) rm -f "$conf" ;;
    *) die "Usage: $0 gpu-mode {glamor|exa|none|modesetting|reset}" ;;
  esac
  log "GPU mode set to: $mode. Reboot to apply:  reboot"
  echo "If the screen still flickers, try in this order: exa, none, modesetting."
  echo "'reset' removes the setting. Settings file: $conf"
}

need_root
check_settings
case "${1:-}" in
  debug-gui)      do_debug_gui ;;
  gpu-mode)       do_gpu_mode "${2:-}" ;;
  check-video)    do_check_video ;;
  bootloader)     do_bootloader ;;
  install)        do_install ;;
  greek)          configure_greek ;;
  save-prefs)     do_save_prefs "${2:-}" ;;
  cleanup)        do_cleanup ;;
  autologin)      do_autologin ;;
  autologin-off)  do_autologin_off ;;
  *) echo "Usage: $0 {install|greek|save-prefs|cleanup|autologin|autologin-off|check-video|bootloader|debug-gui|gpu-mode}"; exit 1 ;;
esac
