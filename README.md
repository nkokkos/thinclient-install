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

It installs two window managers:

To switch between LXQt and XFCE, 

update the target desktop session string in /etc/lightdm/lightdm.conf.d/10-thinclient.conf (setting user-session=lxqt or user-session=xfce) 

and update 

/var/lib/AccountsService/users/thinuser to match (Session=lxqt or Session=xfce), 

then delete the user's cached session file (rm -f /home/thinuser/.dmrc) 

and restart the display manager using 

sudo systemctl restart lightdm,
