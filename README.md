
pacman-key --init
pacman-key --populate archlinux
pacman -Suy archlinux-keyring

# Relaunch without the slow checks:

archinstall --skip-ntp --skip-wkd
