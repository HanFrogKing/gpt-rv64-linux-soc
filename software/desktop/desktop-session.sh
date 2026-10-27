#!/bin/busybox sh
# Run INSIDE the existing read-only-lower/RAM-upper Debian chroot.
# Does not mount storage, install packages, restart Linux or replace a live X.
set -eu
b=/bin/busybox
export PATH=/usr/sbin:/usr/bin:/sbin:/bin HOME=/root LANG=C
export SHELL=/bin/sh SYSTEMD_IGNORE_CHROOT=1
export XDG_RUNTIME_DIR=/tmp/rv64-runtime
export XDG_CACHE_HOME=/tmp/rv64-cache
export XDG_CONFIG_HOME=/tmp/rv64-config
export XAUTHORITY=/tmp/rv64-Xauthority
export FONTCONFIG_FILE=/tmp/r115-fonts.conf
stage() { read -r up rest </proc/uptime; echo "RV64_DESKTOP_STAGE $1 uptime=$up"; }
if [ -S /tmp/.X11-unix/X0 ]; then
 echo 'Existing X display :0; preserve it and refuse a duplicate launch' >&2
 exit 73
fi
for p in /dev/dri/card0 /dev/input/event0 /dev/input/event1; do
 [ -e "$p" ] || { echo "Missing prerequisite $p" >&2; exit 1; }
done
stage prepare
f=/tmp/rv64-fonts-small
d=/tmp/r114-ui-fonts
o=$XDG_CONFIG_HOME/openbox
$b mkdir -p "$f" "$d" "$o" "$XDG_RUNTIME_DIR" "$XDG_CACHE_HOME"
$b chmod 700 "$XDG_RUNTIME_DIR"
for n in 6x13 6x13B cursor; do
 $b ln -sf /usr/share/fonts/X11/misc/$n.pcf.gz "$f/"
done
$b cp /etc/X11/fonts/misc/xfonts-base.alias "$f/fonts.alias"
/usr/bin/mkfontdir "$f"
for n in DejaVuSans DejaVuSans-Bold; do
 $b ln -sf /usr/share/fonts/truetype/dejavu/$n.ttf "$d/"
done
$b cat >"$FONTCONFIG_FILE" <<'FONTS'
<?xml version="1.0"?>
<fontconfig>
 <dir>/tmp/r114-ui-fonts</dir>
 <cachedir>/tmp/rv64-cache/fontconfig-small</cachedir>
 <config><rescan><int>0</int></rescan></config>
</fontconfig>
FONTS
# Drop the unavailable generated Debian menu, retain the stock bindings,
# choose one workspace before the new X server/WM starts, and prevent plain
# desktop wheel movement from switching workspaces.
$b cat >/tmp/r115-rc.sed <<'RC'
/debian-menu.xml/d
s/<number>4<\/number>/<number>1<\/number>/
/<context name="Desktop">/,/<\/context>/{
/<mousebind button="(Up|Down)" /,/<\/mousebind>/d
}
RC
$b sed -E -f /tmp/r115-rc.sed /etc/xdg/openbox/rc.xml >"$o/rc.xml"
$b cat >"$o/menu.xml" <<'MENU'
<?xml version="1.0" encoding="UTF-8"?>
<openbox_menu xmlns="http://openbox.org/">
 <menu id="root-menu" label="RV64 Debian">
  <item label="Terminal"><action name="Execute"><execute>/usr/bin/xterm -title 'Self-designed RV64 Debian'</execute></action></item>
  <separator/>
  <item label="Reload configuration"><action name="Reconfigure"/></item>
 </menu>
</openbox_menu>
MENU
$b sed -e 's,/tmp/rv64-fonts,/tmp/rv64-fonts-small,' \
 -e '/AutoAddDevices/s/false/true/' \
 /etc/X11/xorg-rv64lab.conf >/tmp/xorg-r115-session.conf
$b cat >>/tmp/xorg-r115-session.conf <<'NOGLX'
Section "Module"
 Disable "glx"
EndSection
NOGLX
stage udev
if [ ! -S /run/udev/control ]; then
 /usr/lib/systemd/systemd-udevd --daemon
fi
/usr/bin/udevadm trigger --action=add --subsystem-match=input
/usr/bin/udevadm settle --timeout=180
stage xorg
exec /usr/bin/xinit /usr/local/libexec/rv64-openbox-session -- \
 /usr/lib/xorg/Xorg :0 vt1 -config /tmp/xorg-r115-session.conf \
 -nolisten tcp -noreset -extension GLX -logfile /tmp/Xorg.r115-session.log
