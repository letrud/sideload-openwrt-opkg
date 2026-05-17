# sideload-openwrt-opkg

Sideload OpenWrt's package manager onto any Linux device — a lightweight, self-contained alternative to Entware/Optware.

Run OpenWrt packages side-by-side with stock firmware on routers, NAS devices, and embedded systems. No chroot, no ELF patching, no reflashing. Everything lives under one directory on your writable partition.

## Quick start

**From a system with HTTPS support** (Linux/Mac PC, or router with TLS-capable wget/curl):

```sh
curl -fsSL https://raw.githubusercontent.com/letrud/sideload-openwrt-opkg/main/sideload-openwrt-opkg.sh | sh
```

With options:

```sh
curl -fsSL https://raw.githubusercontent.com/letrud/sideload-openwrt-opkg/main/sideload-openwrt-opkg.sh | sh -s -- -r /data/openwrt-opkg
```

**From a busybox-only router** (no TLS — most stock firmware):

```sh
# download on your PC first
curl -LO https://raw.githubusercontent.com/letrud/sideload-openwrt-opkg/main/sideload-openwrt-opkg.sh

# copy to router
scp sideload-openwrt-opkg.sh root@192.168.1.1:/tmp/

# run on router
ssh root@192.168.1.1
sh /tmp/sideload-openwrt-opkg.sh
```

**After setup:**

```sh
export PATH="/data/openwrt-opkg/wrap:$PATH"
opkg update
opkg install snmpd
snmpd -v
# NET-SNMP version: 5.9.4.pre2
```

Add to your profile to persist across sessions:

```sh
echo 'export PATH="/data/openwrt-opkg/wrap:$PATH"' >> /data/.profile
```

## What it does

1. **Detects your CPU architecture** from `/proc/cpuinfo` and maps it to the correct OpenWrt package feed
2. **Downloads the Packages index** from the official OpenWrt release feeds
3. **Resolves and fetches bootstrap packages** — opkg, musl libc, libgcc, and their dependencies (~800KB total)
4. **Extracts everything** into a single directory (default: `/data/openwrt-opkg`)
5. **Creates wrapper scripts** that invoke each binary through the correct dynamic linker
6. **Configures opkg** to use the official OpenWrt feeds — from there, `opkg install` handles everything

## Options

```
-r DIR    install root      (default: /data/openwrt-opkg)
-v VER    OpenWrt release   (default: 24.10.0)
-a ARCH   override arch     (e.g. aarch64_generic)
-m URL    mirror base URL   (default: http://downloads.openwrt.org)
-h        help
```

## How it works

Stock router firmware uses one C library (typically uClibc or glibc). OpenWrt uses musl. These are completely independent — different dynamic linker, different shared libraries, different search paths. The sideloader exploits this separation:

```
Host firmware                    Sideloaded OpenWrt
─────────────                    ──────────────────
/lib/ld-uClibc.so.0             /data/openwrt-opkg/lib/ld-musl-armhf.so.1
    ↓                                ↓
/lib/libc.so.0 (uClibc)         /data/openwrt-opkg/lib/libc.so (musl)
    ↓                                ↓
/usr/bin/httpd (stock)           /data/openwrt-opkg/usr/sbin/snmpd (OpenWrt)
```

Two loader chains on one kernel, no conflicts.

Every OpenWrt ELF binary has a hardcoded interpreter path (`PT_INTERP`) pointing to `/lib/ld-musl-*.so.1`. On a stock firmware with a read-only root filesystem, that path doesn't exist and can't be created. The wrapper scripts bypass this by invoking the musl linker directly:

```sh
#!/bin/sh
exec /data/openwrt-opkg/lib/ld-musl-armhf.so.1 \
    --library-path /data/openwrt-opkg/lib:/data/openwrt-opkg/usr/lib \
    /data/openwrt-opkg/usr/sbin/snmpd "$@"
```

The `opkg` wrapper additionally runs a scan after each install/upgrade, automatically generating wrappers for newly installed binaries.

## Supported architectures

The script auto-detects your architecture. Currently mapped:

| CPU | OpenWrt arch | Target (for libc) |
|---|---|---|
| x86_64 | `x86_64` | `x86/64` |
| ARM Cortex-A53/A72 (64-bit) | `aarch64_cortex-a53` / `a72` / `generic` | `mediatek/filogic`, `mvebu/cortexa72`, `armsr/armv8` |
| ARM Cortex-A7 (32-bit, hardfloat) | `arm_cortex-a7_neon-vfpv4` | `ipq40xx/generic` |
| ARM Cortex-A9 | `arm_cortex-a9_neon` | `mvebu/cortexa9` |
| ARM Cortex-A15 | `arm_cortex-a15_neon-vfpv4` | `ipq806x/generic` |
| ARM926EJ-S (ARMv5) | `arm_arm926ej-s` | `kirkwood/generic` |
| MIPS 24Kc | `mips_24kc` | `ath79/generic` |
| MIPS (little-endian) | `mipsel_24kc` | `ramips/mt7621` |

Use `-a <arch>` to override if auto-detection picks the wrong feed.

## Busybox compatibility

The script is designed for the most stripped-down busybox environments:

| Missing tool | Workaround |
|---|---|
| `mktemp` | Manual `/tmp/sideload.$$` directory creation |
| `ar` | Not needed — OpenWrt 24.10 ipks are tar.gz archives |
| `readelf` | Architecture detected via `/proc/cpuinfo` |
| `head -c` | ELF detection uses `dd bs=1 skip=1 count=3` |
| `command -v` | Bypassed — busybox applets aren't visible to it |
| `curl` / TLS wget | Plain HTTP to downloads.openwrt.org (Fastly CDN) |

Tested on busybox v1.30.1 (2020) with squashfs read-only root.

## vs Entware

| | Entware | sideload-openwrt-opkg |
|---|---|---|
| Maintained | 2-4 releases/year | OpenWrt's full release cycle |
| Packages | ~2000 | ~5000+ across feeds |
| Package signing | None | usign verification |
| Mirrors | 3× .cn, 1× .ch, primary .ru | Fastly CDN worldwide |
| libc | Pinned to old versions | Current musl from OpenWrt |
| Bootstrap | Needs external tools | Just wget + tar + gunzip |
| Host interference | Shares /opt conventions | Fully self-contained |
| Update path | Separate rebuild pipeline | Direct from OpenWrt — security updates land immediately |

## Troubleshooting

**opkg update shows no output:** Check `/data/openwrt-opkg/etc/opkg/customfeeds.conf` has the feed URLs. Run `opkg update -V3` for verbose output.

**"cannot find dependency libc":** The libc package wasn't registered. Run:
```sh
cat >> /data/openwrt-opkg/usr/lib/opkg/status <<'EOF'
Package: libc
Version: 1.2.5-r4
Status: install ok installed
Architecture: arm_cortex-a7_neon-vfpv4
Provides: musl

EOF
```

**Wrapper not created for a binary:** Run the wrapper generator manually:
```sh
/data/openwrt-opkg/wrap-gen.sh
```

**Wrong architecture detected:** Override with `-a`:
```sh
sh sideload-openwrt-opkg.sh -a aarch64_generic
```

## License

MIT