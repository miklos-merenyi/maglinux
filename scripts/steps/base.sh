#!/bin/bash
# Bootstrap a minimal Debian 12 i386 tree (the slow, download-heavy step).
#   base.sh main     config/packages        -> build/base
#   base.sh rescue   config/rescue-packages -> build/rescue-base
# The result is never modified afterwards: later steps configure a copy of it.
. "$(dirname "$(realpath "$0")")/../lib.sh"

case "${1:-}" in
    main)   pkgfile="$CONFIG/packages";        target="$BASE_DIR" ;;
    rescue) pkgfile="$CONFIG/rescue-packages"; target="$RESCUE_BASE_DIR" ;;
    *) echo "usage: $0 main|rescue" >&2; exit 2 ;;
esac
STEP_NAME="base ($1)"

mapfile -t sources < <(read_list "$CONFIG/sources.list")
proxy_opt=()
[[ -n $APT_PROXY ]] && proxy_opt=(--aptopt="Acquire::http::Proxy \"$APT_PROXY\";")

sudo rm -rf "$target" "$target.tmp"
sudo mmdebstrap --arch=i386 --variant=minbase \
    --aptopt='Apt::Install-Recommends "false";' \
    "${proxy_opt[@]}" \
    --include="$(read_list "$pkgfile" | paste -sd,)" \
    bookworm "$target.tmp" "${sources[@]}"

# The apt proxy is only reachable during the build; mmdebstrap stores --aptopt
# settings in the target, so remove it there.
sudo sed -i '/Acquire::http::Proxy/d' "$target.tmp/etc/apt/apt.conf.d/99mmdebstrap"

sudo mv "$target.tmp" "$target"
