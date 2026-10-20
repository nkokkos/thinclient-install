Sometimes installing behind a firewall creates a problem with ntp


Before running archinstall:

```
Install without ntp:

pacman-key --init

pacman-key --populate archlinux

pacman -Suy archlinux-keyring

archinstall --skip-ntp --skip-wkd

```

After running archinstall:

Download the file with curl:

curl -O https://raw.githubusercontent.com/nkokkos/thinclient-install/main/thin-install.sh

and run it
