#!/usr/bin/env bash
# Packages the Linux release build (flutter build linux --release) as:
#   build/linux/MyTermi-linux-x64-<version>.tar.gz   portable: unpack, run ./mytermi
#   build/linux/mytermi_<version>_amd64.deb          Ubuntu/Debian: sudo apt install ./mytermi_*.deb
#
# Usage (from app/): tool/package_linux.sh v1.2.3
set -euo pipefail

version="${1:?usage: tool/package_linux.sh v1.2.3}"
deb_version="${version#v}"
app_id="com.mytermi.mytermi"
bundle="build/linux/x64/release/bundle"
out="build/linux"

[ -x "$bundle/mytermi" ] || { echo "Build first: flutter build linux --release" >&2; exit 1; }

# --- tar.gz -------------------------------------------------------------------
portable="MyTermi-linux-x64-$version"
stage="$out/stage"
rm -rf "$stage"
mkdir -p "$stage/$portable"
cp -a "$bundle/." "$stage/$portable/"
tar -C "$stage" -czf "$out/$portable.tar.gz" "$portable"

# --- .deb ---------------------------------------------------------------------
root="$stage/deb"
mkdir -p "$root/DEBIAN" "$root/opt/mytermi" "$root/usr/bin" \
  "$root/usr/share/applications" "$root/usr/share/icons/hicolor/scalable/apps"
cp -a "$bundle/." "$root/opt/mytermi/"
ln -s /opt/mytermi/mytermi "$root/usr/bin/mytermi"
cp assets/icon/icon_desktop.svg "$root/usr/share/icons/hicolor/scalable/apps/$app_id.svg"

# The file name matches the GTK application id, so GNOME (Wayland and X11)
# pairs the running window with this entry and its icon.
cat > "$root/usr/share/applications/$app_id.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=MyTermi
GenericName=SSH Client
Comment=SSH client with synced hosts, keys and snippets
Exec=/opt/mytermi/mytermi
Icon=$app_id
Terminal=false
Categories=Network;RemoteAccess;System;TerminalEmulator;
Keywords=ssh;terminal;remote;server;
StartupWMClass=$app_id
StartupNotify=true
EOF

chmod -R u=rwX,go=rX "$root"
size_kb=$(du -sk "$root" | cut -f1)
cat > "$root/DEBIAN/control" <<EOF
Package: mytermi
Version: $deb_version
Section: net
Priority: optional
Architecture: amd64
Installed-Size: $size_kb
Depends: libgtk-3-0t64 | libgtk-3-0, libsecret-1-0, libepoxy0
Recommends: gnome-keyring
Maintainer: MyTermi <dtekltd@users.noreply.github.com>
Homepage: https://github.com/dtekltd/mytermi
Description: SSH client with synced hosts, keys and snippets
 MyTermi is an SSH client for Linux, Windows, Android and iOS. Hosts, keys
 and snippets can be synced between devices with end-to-end encryption.
 Passwords and private keys are kept in the system keyring (Secret Service).
EOF

dpkg-deb --root-owner-group --build "$root" "$out/mytermi_${deb_version}_amd64.deb" >/dev/null
rm -rf "$stage"
ls -la "$out/$portable.tar.gz" "$out/mytermi_${deb_version}_amd64.deb"
