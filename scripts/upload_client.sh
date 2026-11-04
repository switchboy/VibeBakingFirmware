#!/usr/bin/env sh
# Push a probe report to the workstation from Termux (phone) or the head unit.
# Config comes from ./local.env (gitignored, never committed) or environment variables:
#   UPLOAD_HOST=192.168.1.161 UPLOAD_PORT=8765 UPLOAD_TOKEN=<token from upload_server.py>
#   UPLOAD_NAME=probe-phone.md  UPLOAD_FILE=probe.md
#
# Setup on Termux:  pkg install curl openssh
# Run:  sh upload_client.sh            (uses ./probe.md)
#       sh upload_client.sh myreport.md
#
# Alternative without the HTTP endpoint (needs sshd on the workstation):
#   scp "$UPLOAD_FILE" "$UPLOAD_USER@$UPLOAD_HOST:/run/media/Daan/Opslagmonster/VibeBakingFirmware/incoming/"
# scp asks for the password interactively; never put it in a file or in this script.
set -u

cd "$(dirname "$0")" || exit 1
[ -f local.env ] && . ./local.env

UPLOAD_HOST="${UPLOAD_HOST:-192.168.1.161}"
UPLOAD_PORT="${UPLOAD_PORT:-8765}"
UPLOAD_FILE="${1:-${UPLOAD_FILE:-probe.md}}"

if [ ! -f "$UPLOAD_FILE" ]; then
  echo "no report at $UPLOAD_FILE — run probe.sh first" >&2
  exit 1
fi

if [ -z "${UPLOAD_TOKEN:-}" ]; then
  echo "UPLOAD_TOKEN missing. Start the server first: python3 scripts/upload_server.py (it prints TOKEN=...)" >&2
  echo "then put it in ./local.env (gitignored)" >&2
  exit 1
fi

if ! command -v curl >/dev/null 2>&1; then
  echo "curl not installed: pkg install curl" >&2
  exit 1
fi

name="${UPLOAD_NAME:-$(basename "$UPLOAD_FILE")}"
url="http://$UPLOAD_HOST:$UPLOAD_PORT/upload?token=$UPLOAD_TOKEN&name=$name"
echo "uploading $UPLOAD_FILE -> $url"
curl -fsS -T "$UPLOAD_FILE" "$url" && echo "done"
