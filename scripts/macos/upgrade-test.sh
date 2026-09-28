#!/bin/bash
# Обновление поверх прошлой версии, как у человека: ставим прошлый выпуск из Releases, подключаемся,
# ставим новый пакет поверх — служба обновилась, подключения и настройки на месте, VPN вернулся сам.
# Меняет настройки сети Mac — запускать на тестовой машине или в CI.
#
#   sudo scripts/macos/upgrade-test.sh dist/klick-0.9.1.pkg [v0.9.0]
set -uo pipefail

[[ $EUID -eq 0 ]] || { echo "нужен root: sudo $0 $*" >&2; exit 2; }
new_pkg="${1:?путь к новому .pkg}"
[[ -f "$new_pkg" ]] || { echo "нет $new_pkg" >&2; exit 2; }
old_tag="${2:-v0.9.0}"
repo="${GITHUB_REPOSITORY:-limeflash/klick-macos}"
app="/Applications/kl!ck.app"
svc="/Library/PrivilegedHelperTools/klick/klick-service"
cli() { "$app/Contents/MacOS/klick-cli" --prod "$@"; }
work="$(mktemp -d)"
failed=0

pass() { echo "  ✓ $*"; }
fail() { echo "  ✗ $*"; failed=$((failed + 1)); }
check() {
    local what="$1"; shift
    if "$@" >/dev/null 2>&1; then pass "$what"; else fail "$what"; fi
}
wait_for() {
    local t="$1"; shift
    for _ in $(seq 1 $((t * 4))); do "$@" >/dev/null 2>&1 && return 0; sleep 0.25; done
    return 1
}
state_is() { cli status | grep -q "\"vpn\": \"$1\""; }
version_is() { cli about | grep -q "\"version\": \"$1\""; }
install_pkg() { installer -pkg "$1" -target / >"$work/installer.log" 2>&1 || { tail -20 "$work/installer.log"; return 1; }; }
quit_app() { pkill -x klick 2>/dev/null; true; }

cleanup() {
    echo "== уборка"
    [[ -n "${server_pid:-}" ]] && kill "$server_pid" 2>/dev/null
    quit_app
    [[ -x "$svc" ]] && "$svc" uninstall --wipe >/dev/null 2>&1
    rm -rf "$app" "$work"
}
trap cleanup EXIT

new_ver="$(basename "$new_pkg" .pkg)"; new_ver="${new_ver#klick-}"
echo "== $(sw_vers -productName) $(sw_vers -productVersion) $(uname -m): $old_tag → $new_ver"

echo "== прошлая версия $old_tag из Releases"
curl -fsSL -o "$work/old.pkg" "https://github.com/$repo/releases/download/$old_tag/klick-macos.pkg" || { echo "не скачать $old_tag"; exit 1; }
check "установилась" install_pkg "$work/old.pkg"
quit_app
check "служба отвечает" wait_for 20 cli status
check "версия ${old_tag#v}" version_is "${old_tag#v}"

# Тестовый сервер: второе ядро с socks5 на 127.0.0.1:21080, выходит в интернет мимо kl!ck.
iface="$(route -n get default 2>/dev/null | awk '/interface:/ {print $2}')"
cp /Library/PrivilegedHelperTools/klick/mihomo "$work/mihomo-server"
cat > "$work/server.yaml" <<YAML
mixed-port: 0
log-level: warning
interface-name: ${iface:-en0}
listeners:
  - name: s5
    type: socks
    port: 21080
    listen: 127.0.0.1
    udp: true
mode: rule
rules:
  - MATCH,DIRECT
YAML
"$work/mihomo-server" -d "$work" -f "$work/server.yaml" > "$work/server.log" 2>&1 &
server_pid=$!
check "тестовый сервер слушает 21080" wait_for 10 nc -z 127.0.0.1 21080

check "добавить ссылку" cli add "socks5://127.0.0.1:21080#Upgrade"
cli routing all >/dev/null
cli mode proxy >/dev/null
cli connect >/dev/null
check "подключено на старой версии" wait_for 20 state_is connected

echo "== обновление до $new_ver поверх"
check "новый пакет установился поверх" install_pkg "$new_pkg"
quit_app
check "служба отвечает" wait_for 30 cli status
check "версия $new_ver" version_is "$new_ver"
kept() { cli settings | grep -q 'Upgrade'; }
routing_kept() { cli status | grep -q '"routing": "all_vpn"'; }
check "подключение осталось" kept
check "положение «Всё через VPN» осталось" routing_kept
check "VPN вернулся сам после обновления" wait_for 40 state_is connected
check "системный прокси на месте" bash -c 'scutil --proxy | grep -q "HTTPPort : 7890"'
check "ядро от старой версии не осталось" test "$(pgrep -f '/Library/PrivilegedHelperTools/klick/mihomo' | wc -l | tr -d ' ')" = "1"
cli disconnect >/dev/null
check "выключено" wait_for 10 state_is off
check "прокси снят" bash -c '! scutil --proxy | grep -q "HTTPPort : 7890"'

if [[ $failed -gt 0 ]]; then
    echo "--- журнал службы"
    tail -80 "/Library/Application Support/klick/logs/service.log" 2>/dev/null
    echo "== не прошло проверок: $failed"
    exit 1
fi
echo "== все проверки прошли"
