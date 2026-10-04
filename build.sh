#!/usr/bin/env bash
# Build mainline-style OpenWrt for the D-Link DIR-842 rev R1 (RealTek RTL8197F).
#
# The RTL819x/RTL8197F MIPS home-router platform is NOT in upstream OpenWrt
# (mainline's "realtek" target is the RTL838x/930x managed switches only). The
# only tree with RTL8197F target support is the ggbruno fork. This script
# overlays ./files/ (the DIR-842 device support + our fixes) onto a pinned
# ggbruno checkout and builds both a RAM-boot initramfs and a NOR squashfs image.
#
# ⚠ FLASHING REPLACES STOCK FIRMWARE. This is no longer RAM-boot-only: M7.1 cracked
# the D-Link boot signature (a forgeable keyed-MD5, see tools/sign-dlink.py) and the
# squashfs image boots from NOR and survives a power cycle. Back up all 8 MB of NOR
# FIRST and keep it somewhere safe — once you flash, stock exists only in that backup.
# The initramfs image never touches flash and is still the safer way to iterate.
#
# Build environment: the ggbruno fork is from 2020 (kernel 4.14 / gcc 8.4). Use
# a Debian 11 (bullseye)-era build host or container; very new toolchains can
# fail to build the old host tools. Use the Dockerfile in docs/BENCH.md section 7.
#
#   ./build.sh                                  # wired + both WiFi radios (5 GHz + 2.4 GHz) + HW NAT offload + 802.11r
#   PROFILE=~/dir842-profile ./build.sh         # ...plus a private pre-configured profile
#
# Both radios build. The on-SoC 2.4 GHz WMAC needs the vendor rtl8192cd driver;
# it ships in files/ (see the "2.4 GHz radio" step below and the licensing
# rationale in README "Building"), so the overlay places it and the kernel
# builds it like any other in-tree driver — no separate flag or opt-in. This
# used to require a since-withdrawn VENDOR_SDK= flag that never actually
# worked; see docs/WIFI-DUAL-BAND.md §9 item 5 for that history. g3-/g4-*.patch
# in the repo root are the historical record of the port, not a build input —
# the shipped tree already contains everything they describe.
set -e
cd "$(dirname "$0")"
SELF_DIR="$(pwd)"

[ -e openwrt ] && { echo "ERROR: ./openwrt already exists — remove it first." >&2; exit 1; }

# Base tree: ggbruno/openwrt @ 8a0ccb9 (branch Realtek) — the only OpenWrt tree
# with RTL819x/RTL8197F target support.
git clone https://github.com/ggbruno/openwrt
cd openwrt
git checkout 8a0ccb93f3431bcf8f5c5d03d4acc2c8e442de67

# Overlay DIR-842 device support + fixes (path-preserving)
cp -a ../files/. .

# ---- 2.4 GHz radio: builds from files/ ------------------------------------------
# The vendor rtl8192cd driver + include/net/rtl headers ship in files/ (see the
# README's licensing note), so the overlay above just placed them and the kernel
# builds the 2.4 GHz WMAC driver (CONFIG_RTL8192CD=m in the subtarget config,
# kmod-rtl8192cd selected by the seed). The Kernel/Prepare stub in
# target/linux/realtek/Makefile only fires when the driver dir is absent — inert
# here. g3-/g4-*.patch in the repo root are the historical record of the 4.14
# port; the shipped tree already contains everything they describe.
echo ">>> 2.4 GHz vendor driver present: $(find target/linux/realtek/files-4.14/drivers/net/wireless/rtl8192cd -name '*.c' | wc -l) C files"

# ---- optional: private profile overlay (PROFILE=/path/to/profile) ----
# Bakes a private, secret-bearing profile into the image as custom rootfs files
# (OpenWrt copies ./files/ into the rootfs). The profile's
# files/etc/config/{network,wireless,firewall,dhcp} hold the real gateway
# topology + WiFi PSK, so a clean image boots configured. It lives OUTSIDE this
# repo; only its path is passed in:  PROFILE=~/dir842-profile ./build.sh
if [ -n "${PROFILE:-}" ]; then
	[ -d "$PROFILE/files" ] || { echo "ERROR: PROFILE=$PROFILE has no files/ dir." >&2; exit 1; }
	echo ">>> PROFILE=$PROFILE: baking private profile config into the image"
	mkdir -p files
	cp -a "$PROFILE"/files/. files/
	# git records only the exec bit; normalize modes so a group-writable
	# /etc/dropbear doesn't make dropbear reject the dir and lock SSH out.
	find files -type d -exec chmod 755 {} +
	find files -type f -exec chmod 644 {} +
	grep -rlIZ '^#!' files 2>/dev/null | xargs -0 -r chmod 755
	[ -f files/etc/dropbear/authorized_keys ] && chmod 600 files/etc/dropbear/authorized_keys
fi

# Feeds: PINNED, and only the two we need are updated.
#
# The old advice here was "never update feeds" — true for the original initramfs image,
# which used in-tree packages only, but it also meant no web UI. The real constraint is
# that this fork's *default* feeds resolve to CURRENT (master) package versions, which do
# not build against a 19.07-era base: master's luci-base is ucode-based and dies on
# ucode-mod-html / liblucihttp-ucode, and master split miniupnpd into -iptables/-nftables
# so a plain `miniupnpd` dep no longer resolves.
#
# Pinning both feeds to the openwrt-19.07 branch fixes that (Lua-era LuCI, no ucode), so
# R5's LuCI + UPnP + QoS build cleanly. `feeds.conf` overrides feeds.conf.default wholly,
# and it is gitignored inside the OpenWrt tree, which is why it is shipped from here.
cp "$SELF_DIR/feeds.conf" feeds.conf
./scripts/feeds update luci packages
# ★ `luci` (the meta-package) MUST be in this list. seed-m5.config selects
# CONFIG_PACKAGE_luci=y, and if the symbol does not exist at `make defconfig`
# time it is dropped SILENTLY — taking uhttpd, uhttpd-mod-ubus and the admin
# pages with it, and you get an image with no web UI and no error anywhere.
# (That shipped once. The seed now also selects uhttpd/luci-mod-admin-full by
# name so a feed change cannot repeat it.)
./scripts/feeds install luci luci-base luci-mod-admin-full \
                        luci-theme-bootstrap luci-theme-material \
                        luci-app-firewall luci-app-upnp luci-app-opkg \
                        luci-proto-ppp uhttpd uhttpd-mod-ubus \
                        cgi-io miniupnpd qos-scripts

# LuCI 19.07 only exposes WPA/WPA2 choices for wireless types it knows
# explicitly (mac80211/broadcom). The DIR-842 2.4 GHz radio uses our custom
# rtl8192cd netifd backend, whose WPA2-PSK handshake runs inside the vendor
# driver, so stock LuCI incorrectly offers only WEP/open. Teach the UI the
# modes that rtl8192cd.sh actually accepts: psk2, psk-mixed and psk.
LUCI_WIFI_JS="feeds/luci/modules/luci-mod-network/htdocs/luci-static/resources/view/network/wireless.js"
python3 - "$LUCI_WIFI_JS" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
s = p.read_text()
needle = """\t\t\t\telse if (hwtype == 'broadcom') {
\t\t\t\t\tcrypto_modes.push(['psk2',     'WPA2-PSK',                    33]);
\t\t\t\t\tcrypto_modes.push(['psk+psk2', 'WPA-PSK/WPA2-PSK Mixed Mode', 22]);
\t\t\t\t\tcrypto_modes.push(['psk',      'WPA-PSK',                     21]);
\t\t\t\t}
"""
replacement = """\t\t\t\telse if (hwtype == 'rtl8192cd') {
\t\t\t\t\t// Vendor WEXT AP: WPA/WPA2 is handled in-kernel by rtl8192cd,
\t\t\t\t\t// not hostapd. These values map directly in rtl8192cd.sh.
\t\t\t\t\tcrypto_modes.push(['psk2',      'WPA2-PSK',                    35]);
\t\t\t\t\tcrypto_modes.push(['psk-mixed', 'WPA-PSK/WPA2-PSK Mixed Mode', 22]);
\t\t\t\t\tcrypto_modes.push(['psk',       'WPA-PSK',                     21]);
\t\t\t\t}
\t\t\t\telse if (hwtype == 'broadcom') {
\t\t\t\t\tcrypto_modes.push(['psk2',     'WPA2-PSK',                    33]);
\t\t\t\t\tcrypto_modes.push(['psk+psk2', 'WPA-PSK/WPA2-PSK Mixed Mode', 22]);
\t\t\t\t\tcrypto_modes.push(['psk',      'WPA-PSK',                     21]);
\t\t\t\t}
"""
if needle not in s:
    raise SystemExit("ERROR: pinned LuCI wireless.js layout changed; rtl8192cd security patch not applied")
p.write_text(s.replace(needle, replacement, 1))
PY
grep -q "hwtype == 'rtl8192cd'" "$LUCI_WIFI_JS" || {
	echo "ERROR: LuCI rtl8192cd WPA2 support patch missing" >&2
	exit 1
}

# Seed config: shipped from seed-m5.config so this script builds what the port
# actually is today (squashfs flash image + LuCI + PPPoE + offload diagnostics), not
# the historical minimal initramfs. Keep the seed as the single source of truth —
# an inline copy here drifted out of date once already.
# ★ Includes `# CONFIG_KERNEL_CRASHLOG is not set`, which is load-bearing for flash
# boot: OpenWrt's own crashlog handler faults on this SoC and recurses, masking the
# real oops. CONFIG_KERNEL_* is injected AFTER the target config merge, so the
# subtarget's "# CONFIG_CRASHLOG is not set" alone is silently overridden.
cp "$SELF_DIR/seed-m5.config" .config

make defconfig

# DIR-842 LuCI contract: PT-BR and Material are intentional image features, not
# optional feed side effects. Fail early if feed metadata drift makes them vanish.
for cfg in \
	'CONFIG_PACKAGE_luci-theme-material=y' \
	'CONFIG_LUCI_LANG_pt_BR=y' \
	'CONFIG_PACKAGE_luci-i18n-base-pt-br=y' \
	'CONFIG_PACKAGE_luci-i18n-firewall-pt-br=y' \
	'CONFIG_PACKAGE_luci-i18n-upnp-pt-br=y' \
	'CONFIG_PACKAGE_luci-i18n-opkg-pt-br=y'
do
	grep -qx "$cfg" .config || {
		echo "ERROR: required LuCI setting missing after defconfig: $cfg" >&2
		exit 1
	}
done

# CI-only fast preflight: unpack mac80211/backports and apply the Realtek patch
# stack before spending the full build time.  This catches malformed/conflicting
# rtw88 patches with a precise V=s log while remaining a no-op for normal users.
if [ "${DIR842_CI_PREFLIGHT:-0}" = "1" ]; then
	echo ">>> CI preflight: package/kernel/mac80211/prepare (-j1 V=s)"
	make package/kernel/mac80211/prepare -j1 V=s
fi

if ! make -j"$(nproc)"; then
	echo
	echo ">>> Parallel build failed; retrying incrementally with -j1 V=s for diagnostics"
	make -j1 V=s
fi

echo
echo "Build complete. Images are in:"
echo "  $(pwd)/bin/targets/realtek/rtl8197f/"
echo "  - *-GWR1200AC-V1-initramfs-kernel.bin      (serial XMODEM RAM-boot; never writes flash)"
echo "  - *-GWR1200AC-V1-squashfs-factory.bin      (NOR flash via the loader's AUTOBURN)"
echo "  - *-GWR1200AC-V1-squashfs-sysupgrade.bin   (NOR flash via sysupgrade)"
echo
echo "⚠ Both squashfs images REPLACE stock firmware. Back up all 8 MB of NOR first."
echo "  These images are ALREADY signed for the loader (the build runs dlink-md5-sign)."
echo "  Do NOT run tools/sign-dlink.py on them — a second trailer is appended, not replaced."
