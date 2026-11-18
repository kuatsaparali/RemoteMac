#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

mode="${1:---local}"
case "$mode" in
    --local) ;;
    --internet)
        if ! command -v cloudflared >/dev/null; then
            echo 'Для запуска через интернет установите cloudflared: brew install cloudflared' >&2
            exit 1
        fi
        ;;
    *) echo 'Использование: ./start.sh [--local | --internet]' >&2; exit 2 ;;
esac

if ! command -v node >/dev/null || ! node -e 'process.exit(Number(process.versions.node.split(".")[0]) < 22 ? 1 : 0)'; then
    echo 'Установите Node.js 22 или новее: brew install node' >&2
    exit 1
fi

app="$PWD/macos/dist/MacRemote.app"
if [[ ! -x "$app/Contents/MacOS/MacRemote" ]]; then
    ./macos/build.sh
fi
npm --prefix relay ci --no-audit --no-fund

temp_dir="$(mktemp -d)"
relay_pid=''
tunnel_pid=''
cleanup() {
    if [[ -n $tunnel_pid ]]; then kill "$tunnel_pid" 2>/dev/null || true; fi
    if [[ -n $relay_pid ]]; then kill "$relay_pid" 2>/dev/null || true; fi
    rm -rf "$temp_dir"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

port="${PORT:-8787}"
local_address="http://localhost:$port"
session_key="$(node -p "require('node:crypto').randomBytes(32).toString('base64url')")"
MACREMOTE_HOST_KEY="$session_key" BIND_HOST=127.0.0.1 PORT="$port" \
    node relay/server.mjs >"$temp_dir/relay.log" 2>&1 &
relay_pid=$!
for ((attempt = 0; attempt < 30; attempt++)); do
    if ! kill -0 "$relay_pid" 2>/dev/null; then break; fi
    if /usr/bin/grep -q '^MacRemote relay:' "$temp_dir/relay.log"; then break; fi
    sleep 0.2
done
if ! kill -0 "$relay_pid" 2>/dev/null || ! /usr/bin/grep -q '^MacRemote relay:' "$temp_dir/relay.log"; then
    cat "$temp_dir/relay.log" >&2
    echo "Сервер не запустился. Если порт занят, попробуйте PORT=8788 ./start.sh $mode" >&2
    exit 1
fi

address="$local_address"
if [[ $mode == --internet ]]; then
    echo 'Открываем временный HTTPS-туннель…'
    cloudflared tunnel --no-autoupdate --protocol http2 --url "http://127.0.0.1:$port" >"$temp_dir/tunnel.log" 2>&1 &
    tunnel_pid=$!
    address=''
    candidate=''
    deadline=$((SECONDS + 60))
    while (( SECONDS < deadline )); do
        if ! kill -0 "$tunnel_pid" 2>/dev/null; then break; fi
        candidate="$(/usr/bin/grep -Eo 'https://[a-z0-9-]+\.trycloudflare\.com' "$temp_dir/tunnel.log" | head -n 1 || true)"
        if [[ -n "$candidate" ]] && /usr/bin/grep -q 'Registered tunnel connection' "$temp_dir/tunnel.log"; then
            hostname="${candidate#https://}"
            # Avoid caching a negative OS lookup while the new tunnel's DNS record propagates.
            ip="$(node -e 'require("node:dns").resolve4(process.argv[1], (error, ips) => {
                if (!error && ips.length) console.log(ips[0]);
            })' "$hostname")"
            if [[ -n "$ip" ]] && curl -fsS --max-time 4 --resolve "$hostname:443:$ip" \
                "$candidate/" >/dev/null 2>"$temp_dir/probe.log"; then
                address="$candidate"
                break
            fi
        fi
        sleep 1
    done
    if [[ -z "$address" ]]; then
        tail -n 12 "$temp_dir/tunnel.log" >&2
        if [[ -s "$temp_dir/probe.log" ]]; then cat "$temp_dir/probe.log" >&2; fi
        echo 'Туннель не открылся. Повторите запуск или попробуйте ./start.sh --local.' >&2
        exit 1
    fi
fi

printf '\nАдрес для MacRemote: %s\nКлюч для MacRemote:  %s\n\nОставьте это окно открытым. Для остановки нажмите Ctrl+C.\n' "$address" "$session_key"
open "$app"

while kill -0 "$relay_pid" 2>/dev/null; do
    if [[ -n "$tunnel_pid" ]] && ! kill -0 "$tunnel_pid" 2>/dev/null; then
        tail -n 12 "$temp_dir/tunnel.log" >&2
        exit 1
    fi
    sleep 1
done
cat "$temp_dir/relay.log" >&2
exit 1
