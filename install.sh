#!/usr/bin/env sh
# install.sh — fetch liteflow.conf via fetch-conf.sh from a private repo
# Usage: ./install.sh [-y] <host-name>
# Example: ./install.sh node-01.example.internal
#   -y or ASSUME_YES=1 : auto-continue when optional tools are missing

set -eu

# -------- Config (can be overridden via env) --------
: "${CONF_REPO:=git@github.com:xnervwang/liteflow-conf-repo.git}"
: "${FETCH_URL:=https://raw.githubusercontent.com/xnervwang/Liteflow/refs/heads/venus/scripts/fetch-conf.sh}"
: "${DEST_FILE:=liteflow.conf}"
: "${MODE:=--force}"   # --force | --backup
# ---------------------------------------------------

usage() {
  echo "Usage: $0 [-y] <host-name>"
  echo "Example: $0 node-01.example.internal"
  exit 1
}

# parse -y
YES=0
if [ "${ASSUME_YES:-}" = "1" ]; then YES=1; fi
if [ "${1:-}" = "-y" ]; then YES=1; shift; fi

HOST="${1:-}"; [ -n "$HOST" ] || usage
SRC_PATH="output/${HOST}.conf"

need() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Error: required command '$1' not found in PATH." >&2
    exit 127
  }
}

# ---------- detect deps ----------
# downloader: curl or wget (need ONE)
DOWNLOADER=""
if command -v curl >/dev/null 2>&1; then DOWNLOADER="curl"; fi
if [ -z "$DOWNLOADER" ] && command -v wget >/dev/null 2>&1; then DOWNLOADER="wget"; fi
[ -n "$DOWNLOADER" ] || { echo "Error: need 'curl' or 'wget'." >&2; exit 127; }

# required
need git
need bash

# SSH only when repo uses SSH
case "$CONF_REPO" in
  git@*|ssh://*) need ssh ;;
esac

# optional (warn + confirm)
missing_opt=""
command -v jq  >/dev/null 2>&1 || missing_opt="${missing_opt} jq"
command -v cmp >/dev/null 2>&1 || missing_opt="${missing_opt} cmp"

if [ -n "$missing_opt" ]; then
  echo "Warning: optional tools missing:${missing_opt}"
  echo "  - jq  : enables JSON validation after download"
  echo "  - cmp : enables 'no-change' detection before overwrite"
  if [ "$YES" -ne 1 ]; then
    printf "Continue without these? [y/N]: "
    # shellcheck disable=SC2162
    read ans || ans=""
    case "$ans" in
      y|Y|yes|YES) : ;;
      *) echo "Aborted."; exit 2 ;;
    esac
  fi
fi

# ---------- fetch helper script ----------
TMPDIR="$(mktemp -d)"
cleanup() { rm -rf "$TMPDIR"; }
trap cleanup EXIT

FETCH_SH="$TMPDIR/fetch-conf.sh"
echo "[install] downloading fetch-conf.sh from: $FETCH_URL"
if [ "$DOWNLOADER" = "curl" ]; then
  curl -fsSL "$FETCH_URL" -o "$FETCH_SH"
else
  wget -qO "$FETCH_SH" "$FETCH_URL"
fi
chmod +x "$FETCH_SH"

echo "[install] repo:   $CONF_REPO"
echo "[install] source: $SRC_PATH"
echo "[install] dest:   ./$DEST_FILE"
echo "[install] mode:   $MODE"

# ---------- run fetch ----------
# fetch-conf.sh expects: bash fetch-conf.sh git [--force|--backup] <repo> <src> <dest>
bash "$FETCH_SH" git "$MODE" "$CONF_REPO" "$SRC_PATH" "./$DEST_FILE"

echo "[install] done."
