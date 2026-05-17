#!/bin/sh
#
# sideload-openwrt-opkg.sh
#
# Bootstrap OpenWrt's opkg on any Linux device. Everything lives under
# one writable directory (default: /data/openwrt-opkg). After setup:
#
#   export PATH="/data/openwrt-opkg/wrap:$PATH"
#   opkg update
#   opkg install snmpd
#
# Works on busybox-only systems with read-only root filesystems.
# No ar, mktemp, readelf, head -c, or command -v required.
#
# Pipe-safe:
#   wget -O- http://example.com/sideload-openwrt-opkg.sh | sh
#   wget -O- http://example.com/sideload-openwrt-opkg.sh | sh -s -- -r /myroot

main() {
set -eu

# ---------- defaults ----------
ROOT="/data/openwrt-opkg"
VER="24.10.0"
MIRROR="http://downloads.openwrt.org"
ARCH=""

usage() {
    cat <<'EOF'
Usage: sideload-openwrt-opkg.sh [opts]

Options:
  -r DIR    install root      (default: /data/openwrt-opkg)
  -v VER    OpenWrt release   (default: 24.10.0)
  -a ARCH   override arch     (e.g. aarch64_generic)
  -m URL    mirror base URL   (default: http://downloads.openwrt.org)
  -h        help
EOF
}

while getopts "r:v:a:m:h" opt; do
    case "$opt" in
        r) ROOT="$OPTARG" ;;
        v) VER="$OPTARG" ;;
        a) ARCH="$OPTARG" ;;
        m) MIRROR="$OPTARG" ;;
        h) usage; exit 0 ;;
        *) usage >&2; exit 2 ;;
    esac
done

# ---------- portable helpers ----------
make_tmpdir() {
    if command -v mktemp >/dev/null 2>&1; then
        mktemp -d 2>/dev/null && return 0
    fi
    i=0
    while :; do
        d="/tmp/sideload.$$.$i"
        if mkdir "$d" 2>/dev/null; then echo "$d"; return 0; fi
        i=$((i + 1)); [ "$i" -gt 999 ] && return 1
    done
}

# busybox applets aren't found by command -v — just try them
fetch_to() {
    wget -O "$2" "$1" 2>/dev/null && return 0
    curl -fSL -o "$2" "$1" 2>/dev/null && return 0
    echo "error: neither wget nor curl could fetch $1" >&2
    return 1
}

# map package arch -> canonical target (for libc, libgcc)
target_for_arch() {
    case "$1" in
        x86_64)                      echo "x86/64" ;;
        aarch64_generic)             echo "armsr/armv8" ;;
        aarch64_cortex-a53)          echo "mediatek/filogic" ;;
        aarch64_cortex-a72)          echo "mvebu/cortexa72" ;;
        arm_cortex-a7_neon-vfpv4)    echo "ipq40xx/generic" ;;
        arm_cortex-a7_vfpv4)         echo "at91/sama7" ;;
        arm_cortex-a7)               echo "mediatek/mt7629" ;;
        arm_cortex-a9_neon)          echo "mvebu/cortexa9" ;;
        arm_cortex-a9)               echo "bcm53xx/generic" ;;
        arm_cortex-a15_neon-vfpv4)   echo "ipq806x/generic" ;;
        arm_cortex-a8_vfpv3)         echo "ti/am33xx" ;;
        arm_cortex-a5_vfpv4)         echo "at91/sama5" ;;
        arm_arm926ej-s)              echo "kirkwood/generic" ;;
        arm_arm1176jzf-s_vfp)        echo "bcm27xx/bcm2708" ;;
        mips_24kc)                   echo "ath79/generic" ;;
        mipsel_24kc)                 echo "ramips/mt7621" ;;
        mipsel_74kc)                 echo "bcm47xx/mips74k" ;;
        i386_pentium4)               echo "x86/generic" ;;
        *) return 1 ;;
    esac
}

# ---------- arch detection ----------
detect_arch() {
    m=$(uname -m)
    case "$m" in
        x86_64)  echo "x86_64" ;;
        aarch64)
            p=$(awk '/CPU part/{print $4;exit}' /proc/cpuinfo 2>/dev/null||true)
            case "$p" in
                0xd03) echo "aarch64_cortex-a53" ;;
                0xd08) echo "aarch64_cortex-a72" ;;
                *)     echo "aarch64_generic" ;;
            esac ;;
        armv7l)
            # armv7l is always hardfloat (softfloat reports as armv5tel)
            p=$(awk '/CPU part/{print $4;exit}' /proc/cpuinfo 2>/dev/null||true)
            case "$p" in
                0xc07) echo "arm_cortex-a7_neon-vfpv4" ;;
                0xc09) echo "arm_cortex-a9_neon" ;;
                0xc0f) echo "arm_cortex-a15_neon-vfpv4" ;;
                0xd03) echo "arm_cortex-a7_neon-vfpv4" ;;
                0xd08) echo "arm_cortex-a7_neon-vfpv4" ;;
                *)     echo "arm_cortex-a7_neon-vfpv4" ;;
            esac ;;
        armv5*) echo "arm_arm926ej-s" ;;
        mips)   echo "mips_24kc" ;;
        mipsel) echo "mipsel_24kc" ;;
        i?86)   echo "i386_pentium4" ;;
        *)      echo "unknown" >&2; return 1 ;;
    esac
}

[ -z "$ARCH" ] && ARCH=$(detect_arch)
BASE="$MIRROR/releases/$VER/packages/$ARCH"

echo ">> arch:    $ARCH"
echo ">> release: $VER"
echo ">> root:    $ROOT"
echo ">> feeds:   $BASE"
echo

# ---------- working dir ----------
WORK=$(make_tmpdir)
trap 'rm -rf "$WORK"' EXIT

# ---------- fetch package indices ----------
echo ">> fetching package index..."
if fetch_to "$BASE/base/Packages.gz" "$WORK/idx.gz" && [ -s "$WORK/idx.gz" ]; then
    gunzip -c "$WORK/idx.gz" > "$WORK/idx"
fi

if [ ! -s "$WORK/idx" ]; then
    echo "error: could not fetch index from $BASE/base/" >&2
    echo "       arch '$ARCH' may not exist for release $VER" >&2
    echo "       try -a <arch> or -v <older-release>" >&2
    exit 1
fi

n=$(grep -c '^Package:' "$WORK/idx" 2>/dev/null || echo 0)
echo "   $n packages in base feed"

# also fetch target packages (libc, libgcc live here, not in base)
TBASE=""
TARGET=$(target_for_arch "$ARCH" 2>/dev/null) || TARGET=""
if [ -n "$TARGET" ]; then
    TBASE="$MIRROR/releases/$VER/targets/$TARGET/packages"
    echo ">> fetching target packages index ($TARGET)..."
    if fetch_to "$TBASE/Packages.gz" "$WORK/tidx.gz" && [ -s "$WORK/tidx.gz" ]; then
        gunzip -c "$WORK/tidx.gz" > "$WORK/tidx"
        echo "" >> "$WORK/idx"
        cat "$WORK/tidx" >> "$WORK/idx"
        tn=$(grep -c '^Package:' "$WORK/tidx" 2>/dev/null || echo 0)
        echo "   $tn packages in target feed"
    fi
fi
echo

# ---------- package lookup ----------
pkg_info() {
    awk -v want="$1" '
        BEGIN { RS=""; FS="\n" }
        {
            n=""; f=""; d=""
            for(i=1;i<=NF;i++){
                if(match($i,/^Package:[ \t]*/))  n=substr($i,RLENGTH+1)
                if(match($i,/^Filename:[ \t]*/)) f=substr($i,RLENGTH+1)
                if(match($i,/^Depends:[ \t]*/))  d=substr($i,RLENGTH+1)
            }
            gsub(/\r/,"",n)
            if(n==want){print "F="f; print "D="d; exit}
        }
    ' "$WORK/idx"
}

# ---------- dependency resolver ----------
: > "$WORK/seen"
: > "$WORK/order"

resolve() {
    pkg=$(echo "$1" | sed 's/(.*)//; s/^[ \t]*//; s/[ \t]*$//')
    [ -z "$pkg" ] && return 0
    grep -Fxq "$pkg" "$WORK/seen" 2>/dev/null && return 0
    echo "$pkg" >> "$WORK/seen"

    info=$(pkg_info "$pkg")
    [ -z "$info" ] && { echo "   skip: $pkg (not found)" >&2; return 0; }

    fname=$(echo "$info" | sed -n 's/^F=//p')
    deps=$(echo "$info"  | sed -n 's/^D=//p')

    if [ -n "$deps" ]; then
        echo "$deps" | tr ',' '\n' | while read -r d; do
            resolve "$d"
        done
    fi

    [ -n "$fname" ] && echo "$fname" >> "$WORK/order"
}

echo ">> resolving bootstrap deps for: opkg"
resolve opkg

# force libc — it's not in the Packages index (baked into firmware)
# but the .ipk exists on the server. Derive version from libpthread.
LIBC_DONE=0
if ! grep -q "^libc_" "$WORK/order" 2>/dev/null; then
    # find libpthread's filename directly (same musl version = same libc version)
    lp_fname=$(awk '/^Filename:.*libpthread_/{sub(/^Filename:[ \t]*/,"");print;exit}' "$WORK/idx")
    if [ -n "$lp_fname" ]; then
        libc_fname=$(echo "$lp_fname" | sed 's/libpthread/libc/')
        echo "   libc: not indexed, will fetch $libc_fname directly"
        echo "$libc_fname" >> "$WORK/order"
        LIBC_DONE=1
    else
        echo "   warning: could not determine libc version" >&2
    fi
fi

echo
echo ">> bootstrap packages:"
cat "$WORK/order"
echo

# ---------- ipk extractor ----------
# OpenWrt 24.10 ipks are gzip-compressed tar archives containing
# debian-binary, control.tar.*, data.tar.*
ipk_extract() {
    ipk="$1"
    dest="$2"
    tmp="$WORK/ipkx"
    rm -rf "$tmp"
    mkdir -p "$tmp"

    tar xzf "$ipk" -C "$tmp" 2>/dev/null || {
        echo "(not tar.gz)" >&2; rm -rf "$tmp"; return 1
    }

    for f in "$tmp"/data.tar.*; do
        [ -f "$f" ] || continue
        case "$f" in
            *.gz)  tar xzf "$f" -C "$dest" 2>/dev/null; rm -rf "$tmp"; return 0 ;;
            *.xz)  xz -dc "$f" | tar xf - -C "$dest" 2>/dev/null; rm -rf "$tmp"; return 0 ;;
            *.zst)
                if zstd -dc "$f" 2>/dev/null | tar xf - -C "$dest" 2>/dev/null; then
                    rm -rf "$tmp"; return 0
                else
                    echo "(data.tar.zst — no zstd on this system)" >&2
                    rm -rf "$tmp"; return 1
                fi ;;
        esac
    done

    echo "(no data.tar.* found)" >&2
    rm -rf "$tmp"
    return 1
}

# ---------- create directory structure ----------
mkdir -p "$ROOT/wrap" \
         "$ROOT/var/opkg-lists" \
         "$ROOT/var/lock" \
         "$ROOT/tmp" \
         "$ROOT/etc/opkg" \
         "$ROOT/usr/lib/opkg/info"

# ---------- download & extract ----------
echo ">> downloading and extracting..."
while read -r fname; do
    [ -z "$fname" ] && continue
    out="$WORK/$(basename "$fname")"
    printf '   %-40s ' "$(basename "$fname")"
    ok=0
    if fetch_to "$BASE/base/$fname" "$out" && [ -s "$out" ]; then
        ok=1
    elif [ -n "$TBASE" ] && fetch_to "$TBASE/$fname" "$out" && [ -s "$out" ]; then
        ok=1
    fi
    if [ "$ok" -eq 1 ]; then
        ipk_extract "$out" "$ROOT" && echo "ok" || echo "EXTRACT FAIL"
    else
        echo "DOWNLOAD FAIL"
    fi
done < "$WORK/order"

# ---------- find musl linker ----------
LINKER=""
for f in "$ROOT"/lib/ld-musl-*.so.1; do
    [ -f "$f" ] && LINKER="$f" && break
done

if [ -z "$LINKER" ]; then
    echo
    echo "error: musl linker not found under $ROOT/lib/" >&2
    echo "       libc package may be missing or this arch uses a different layout" >&2
    exit 1
fi
echo
echo ">> linker: $LINKER"

# ---------- register libc in opkg status (it was installed outside opkg) ----------
if [ "$LIBC_DONE" -eq 1 ]; then
    libc_ver=$(echo "$libc_fname" | sed 's/^libc_//; s/_[a-z].*$//')
    if ! grep -q '^Package: libc$' "$ROOT/usr/lib/opkg/status" 2>/dev/null; then
        cat >> "$ROOT/usr/lib/opkg/status" <<LIBCEOF
Package: libc
Version: $libc_ver
Status: install ok installed
Architecture: $ARCH
Provides: musl

LIBCEOF
        touch "$ROOT/usr/lib/opkg/info/libc.list"
        echo ">> registered libc $libc_ver in opkg status"
    fi
fi

# ---------- opkg.conf + feeds ----------
cat > "$ROOT/etc/opkg.conf" <<EOF
dest root /
lists_dir ext /var/opkg-lists
option tmp_dir $ROOT/tmp

arch all 100
arch $ARCH 200
EOF

cat > "$ROOT/etc/opkg/customfeeds.conf" <<EOF
src/gz openwrt_base     $MIRROR/releases/$VER/packages/$ARCH/base
src/gz openwrt_packages $MIRROR/releases/$VER/packages/$ARCH/packages
src/gz openwrt_routing  $MIRROR/releases/$VER/packages/$ARCH/routing
EOF
echo ">> opkg.conf + feeds written"

# ---------- find opkg binary ----------
OPKG_BIN=""
for d in bin usr/bin sbin usr/sbin; do
    if [ -x "$ROOT/$d/opkg" ]; then
        OPKG_BIN="$ROOT/$d/opkg"
        break
    fi
done
if [ -z "$OPKG_BIN" ]; then
    echo "warning: opkg binary not found" >&2
fi

# ---------- wrap-gen.sh ----------
cat > "$ROOT/wrap-gen.sh" <<WGEOF
#!/bin/sh
ROOT="$ROOT"
LINKER="$LINKER"
for dir in bin sbin usr/bin usr/sbin; do
    [ -d "\$ROOT/\$dir" ] || continue
    for f in "\$ROOT/\$dir"/*; do
        [ -f "\$f" ] && [ -x "\$f" ] || continue
        name=\$(basename "\$f")
        [ -f "\$ROOT/wrap/\$name" ] && continue
        # ELF detection: bytes 2-4 are "ELF" (no head -c on old busybox)
        elfmag=\$(dd if="\$f" bs=1 skip=1 count=3 2>/dev/null)
        [ "\$elfmag" = "ELF" ] || continue
        printf '#!/bin/sh\nexport PATH="%s/wrap:\$PATH"\nexec "%s" --library-path "%s/lib:%s/usr/lib" "%s" "\$@"\n' \\
            "\$ROOT" "\$LINKER" "\$ROOT" "\$ROOT" "\$f" > "\$ROOT/wrap/\$name"
        chmod +x "\$ROOT/wrap/\$name"
        echo "   + \$name"
    done
done
WGEOF
chmod +x "$ROOT/wrap-gen.sh"

# ---------- opkg wrapper ----------
cat > "$ROOT/wrap/opkg" <<OKEOF
#!/bin/sh
ROOT="$ROOT"
LINKER="$LINKER"
export PATH="\$ROOT/wrap:\$PATH"

"\$LINKER" --library-path "\$ROOT/lib:\$ROOT/usr/lib" \\
    "$OPKG_BIN" --offline-root "\$ROOT" "\$@"
rc=\$?

case "\$1" in
    install|upgrade|remove)
        echo ">> updating wrappers..."
        "\$ROOT/wrap-gen.sh"
        ;;
esac
exit \$rc
OKEOF
chmod +x "$ROOT/wrap/opkg"
echo ">> opkg wrapper created"

# ---------- generate wrappers for bootstrap binaries ----------
echo ">> generating wrappers..."
"$ROOT/wrap-gen.sh"

# ---------- done ----------
echo
echo "============================="
echo "  setup complete"
echo "============================="
echo
echo "add to your profile:"
echo "  export PATH=\"$ROOT/wrap:\$PATH\""
echo
echo "then:"
echo "  opkg update"
echo "  opkg install snmpd"
echo
echo "every 'opkg install' auto-generates wrappers"
echo "for newly installed binaries."
echo
echo "root: $ROOT"
du -sh "$ROOT" 2>/dev/null | awk '{print "size: "$1}'
}

main "$@"
