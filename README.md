
pacman-key --init
pacman-key --populate archlinux
pacman -Suy archlinux-keyring

archinstall --skip-ntp --skip-wkd
