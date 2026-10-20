Sometimes installing with behind a firewall creates a problem with ntp

```
Install without ntp:

pacman-key --init

pacman-key --populate archlinux

pacman -Suy archlinux-keyring

archinstall --skip-ntp --skip-wkd

```
