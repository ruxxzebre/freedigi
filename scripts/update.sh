#!/bin/bash
# Run from Terminal: bash ~/Applications/update.sh [user@server]
set -euo pipefail
[[ $# -le 1 ]] || { echo 'Usage: update.sh [user@server]' >&2; exit 1; }
[[ "$(uname -s)" == Darwin ]] || { echo 'Run this script on your Mac.' >&2; exit 1; }
server="${1:-nesko@chaiky.dev}"
[[ -n "$server" && "$server" != -* && "$server" != *:* && "$server" != *[[:space:]]* ]] || {
    echo 'Use an SSH hostname, optionally prefixed with user@.' >&2; exit 1;
}
download_dir=$(mktemp -d "${TMPDIR:-/tmp}/controllab-update.XXXXXX")
trap 'rm -rf -- "$download_dir"' EXIT
log_dir="$HOME/Library/Logs/ControlLab"
mkdir -p "$log_dir"
printf 'Update log: %s/update.log\n' "$log_dir"
{
    date
    printf 'Downloading installer from %s…\n' "$server"
    scp -o ConnectTimeout=15 -o ServerAliveInterval=15 -o ServerAliveCountMax=3 \
        "${server}:/srv/stacks-ssd/projects/decofly/install-controllab-mac.sh" "$download_dir/install.sh"
    bash "$download_dir/install.sh" "$server"
} 2>&1 | tee "$log_dir/update.log"
