#!/bin/bash
# Out-of-tree kernel modules (third_party/), compiled for the image's kernel:
#   third_party/alim6117_wdt -> build/kmod/alim6117_wdt.ko
# They are compiled in a build chroot (build/kbuild: gcc, make and the headers of
# exactly the kernel installed in build/base), so the image needs no compiler.
# The chroot is bootstrapped again only when the kernel changes (make refresh).
. "$(dirname "$(realpath "$0")")/../lib.sh"

KBUILD_DIR="$B/kbuild"
OUT="$B/kmod"

kpkg=$(sudo chroot "$BASE_DIR" dpkg-query -W -f '${db:Status-Abbrev} ${Package} ${Version}\n' \
       'linux-image-[0-9]*' | awk '$1 == "ii" && $2 !~ /-unsigned$/ {print $2, $3; exit}')
[[ -n $kpkg ]] || { echo "ERROR: no linux-image package in $BASE_DIR" >&2; exit 1; }
read -r kimage kversion <<<"$kpkg"
kver=${kimage#linux-image-}             # e.g. 6.1.0-56-686
want="linux-headers-$kver=$kversion"    # the headers of exactly this kernel build

if [[ ! -f $KBUILD_DIR/.headers ]] || [[ $(cat "$KBUILD_DIR/.headers") != "$want" ]]; then
    mapfile -t sources < <(read_list "$CONFIG/sources.list")
    proxy_opt=()
    [[ -n $APT_PROXY ]] && proxy_opt=(--aptopt="Acquire::http::Proxy \"$APT_PROXY\";")
    sudo rm -rf "$KBUILD_DIR" "$KBUILD_DIR.tmp"
    if ! sudo mmdebstrap --arch=i386 --variant=minbase \
            --aptopt='Apt::Install-Recommends "false";' "${proxy_opt[@]}" \
            --include="make,gcc,$want" bookworm "$KBUILD_DIR.tmp" "${sources[@]}"; then
        echo "ERROR: cannot install $want: the archive may have a newer build of" \
             "this kernel by now; run 'make refresh' to rebuild everything with it" >&2
        exit 1
    fi
    echo "$want" | sudo tee "$KBUILD_DIR.tmp/.headers" >/dev/null
    sudo mv "$KBUILD_DIR.tmp" "$KBUILD_DIR"
fi

sudo rm -rf "$KBUILD_DIR/src" "$OUT"
sudo cp -r "$REPO/third_party/alim6117_wdt" "$KBUILD_DIR/src"
sudo chroot "$KBUILD_DIR" make -s -C "/usr/src/linux-headers-$kver" M=/src modules
mkdir -p "$OUT"
cp "$KBUILD_DIR/src/alim6117_wdt.ko" "$OUT/"
vermagic=$(/sbin/modinfo -F vermagic "$OUT/alim6117_wdt.ko")
[[ ${vermagic%% *} == "$kver" ]] ||
    { echo "ERROR: alim6117_wdt.ko is for '$vermagic', not $kver" >&2; exit 1; }
echo "$kver" > "$OUT/kernel"
echo "alim6117_wdt.ko built for $kver"
