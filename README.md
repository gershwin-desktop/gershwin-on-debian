# Gershwin-on-Debian Live ISO builder

> [!WARNING]  
> The ISOs generated in this repository are for developers and may contain known issues.

Gershwin build and installation takes place in [010-gnustep.chroot](config/hooks/normal/010-gnustep.chroot)

Autologin is controlled by the display manager, and if there isn't one, startx is run from
`/etc/profile.d/zz-live-config_xinit.sh`. 
This file is created by `/lib/live/config/0140-xinit` from the `live-config` package.

## Debian Live Manual 

https://live-team.pages.debian.net/live-manual/html/live-manual/index.en.html
