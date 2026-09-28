#!/bin/bash
# Сквозная проверка kl!ck на настоящем Mac: ставит службу из kl!ck.app, поднимает тестовый «VPN-сервер»
# (второй mihomo с socks5 на 127.0.0.1:21080) и проходит сценарии: прокси, TUN с подменой DNS,
# Kill Switch, падение службы, удаление. Меняет настройки сети Mac и в конце возвращает их —
# запускать на тестовой машине или в CI (GitHub Actions, macOS), а не на рабочем компьютере.
#
#   sudo scripts/macos/smoke-test.sh "dist/kl!ck.app"
set -uo pipefail

[[ $EUID -eq 0 ]] || { echo "нужен root: sudo $0 $*" >&2; exit 2; }
app="${1:-dist/kl!ck.app}"
[[ -x "$app/Contents/MacOS/klick-service" ]] || { echo "нет $app" >&2; exit 2; }
app="$(cd "$(dirname "$app")" && pwd)/$(basename "$app")"

svc="/Library/PrivilegedHelperTools/klick/klick-service"
core="/Library/PrivilegedHelperTools/klick/mihomo"
cli() { "$app/Contents/MacOS/klick-cli" --prod "$@"; }
work="$(mktemp -d)"
log="/Library/Application Support/klick/logs/service.log"
failed=0
probe="https://www.gstatic.com/generate_204"

pass() { echo "  ✓ $*"; }
fail() { echo "  ✗ $*"; failed=$((failed + 1)); }
check() { # check "описание" команда…
    local what="$1"; shift
    if "$@" >/dev/null 2>&1; then pass "$what"; else fail "$what"; fi
}
wait_for() { # wait_for секунд команда…
    local t="$1"; shift
    for _ in $(seq 1 $((t * 4))); do "$@" >/dev/null 2>&1 && return 0; sleep 0.25; done
    return 1
}
state_is() { cli status | grep -q "\"vpn\": \"$1\""; }
http_with() { local bin="$1"; shift; [[ "$("$bin" -s -o /dev/null -m 10 -w '%{http_code}' "$@" "$probe")" == "204" ]]; }
http_ok() { http_with /usr/bin/curl "$@"; }
kscurl() { http_with /Users/Shared/klick-ks/tool/kscurl "$@"; }
first_service() { networksetup -listallnetworkservices | sed 1d | grep -v '^\*' | head -1; }
proxy_on() { scutil --proxy | grep -q "HTTPEnable : 1" && scutil --proxy | grep -q "HTTPPort : 7890"; }
dns_ours() { scutil --dns | grep -q "nameserver\[0\] : 198.18.0.2"; }
tun_up() { ifconfig | grep -q "inet 198.18.0.1 "; }

cleanup() {
    echo "== уборка"
    [[ -n "${server_pid:-}" ]] && kill "$server_pid" 2>/dev/null
    [[ -x "$svc" ]] && "$svc" uninstall --wipe >/dev/null 2>&1
    rm -rf "$work"
}
trap cleanup EXIT

echo "== $(sw_vers -productName) $(sw_vers -productVersion) $(uname -m)"
echo "   сетевая служба: $(first_service); DNS: $(networksetup -getdnsservers "$(first_service)" | tr '\n' ' ')"

echo "== установка службы"
"$app/Contents/MacOS/klick-service" install || { echo "install не удался"; exit 1; }
check "служба в launchd" launchctl print system/app.klick.service
check "сокет /var/run/klick.sock появился" wait_for 15 test -S /var/run/klick.sock
check "сокет root:staff 660" test "$(stat -f '%Su:%Sg %Lp' /var/run/klick.sock)" = "root:staff 660"
check "папка данных только для root" test "$(stat -f '%Su %Lp' '/Library/Application Support/klick')" = "root 700"
check "служба отвечает" wait_for 10 cli status
cli about

echo "== тестовый сервер"
cat > "$work/server.yaml" <<'YAML'
mixed-port: 0
log-level: warning
listeners:
  - { name: s5, type: socks, port: 21080, listen: 127.0.0.1, udp: true }
mode: rule
rules: [MATCH,DIRECT]
YAML
# Копия ядра: по пути установленного ядра проверка ниже считает ядра службы.
cp "$core" "$work/mihomo-server"
"$work/mihomo-server" -d "$work" -f "$work/server.yaml" > "$work/server.log" 2>&1 &
server_pid=$!
check "тестовый сервер слушает 21080" wait_for 10 nc -z 127.0.0.1 21080

echo "== подключение и серверы"
check "добавить ссылку" cli add "socks5://127.0.0.1:21080#CI"
check "серверы (проверочное ядро)" cli servers
cli latency | grep -q '"delay": [0-9]' && pass "задержка измерена" || fail "задержка измерена"

echo "== режим «Системный прокси»"
cli mode proxy >/dev/null
cli connect >/dev/null
check "подключено" wait_for 20 state_is connected
check "системный прокси 127.0.0.1:7890" proxy_on
check "страница через порт 7890" http_ok -x http://127.0.0.1:7890
cli ip | head -8
cli disconnect >/dev/null
check "выключено" state_is off
check "прокси снят" bash -c '! scutil --proxy | grep -q "HTTPPort : 7890"'

echo "== режим VPN (TUN)"
cli mode tun >/dev/null
cli connect >/dev/null
check "подключено" wait_for 20 state_is connected
check "адаптер utun с 198.18.0.1" tun_up
check "DNS подменён на 198.18.0.2" dns_ours
check "имя отвечает подменным адресом" bash -c 'dscacheutil -q host -a name www.gstatic.com | grep -q "ip_address: 198.18."'
check "страница через TUN" http_ok
cli ip | grep -E '"dns_protected"|"ipv4"' | head -3
cli disconnect >/dev/null
check "адаптер убран" wait_for 10 bash -c '! ifconfig | grep -q "inet 198.18.0.1 "'
check "DNS возвращён" bash -c '! scutil --dns | grep -q "nameserver\[0\] : 198.18.0.2"'
check "страница напрямую после VPN" http_ok

echo "== Kill Switch"
mkdir -p /Users/Shared/klick-ks/tool
cp /usr/bin/curl /Users/Shared/klick-ks/tool/kscurl
check "программа до Kill Switch ходит напрямую" kscurl
check "добавить в Kill Switch" cli ks add /Users/Shared/klick-ks/tool
check "страж поднял адаптер при выключенном VPN" wait_for 15 tun_up
check "защищённая программа без VPN не выходит" bash -c "! /Users/Shared/klick-ks/tool/kscurl -s -o /dev/null -m 8 $probe"
check "остальные ходят напрямую" http_ok
cli connect >/dev/null
check "VPN (TUN) подключён" wait_for 20 state_is connected
check "защищённая программа ходит через VPN" kscurl
cli disconnect >/dev/null
check "страж вернулся после отключения" wait_for 15 tun_up
check "убрать из Kill Switch" cli ks rm /Users/Shared/klick-ks/tool
check "страж остановлен" wait_for 10 bash -c '! ifconfig | grep -q "inet 198.18.0.1 "'
check "программа снова ходит напрямую" kscurl
rm -rf /Users/Shared/klick-ks

echo "== падение службы"
cli mode proxy >/dev/null
cli connect >/dev/null
check "подключено" wait_for 20 state_is connected
pid="$(launchctl print system/app.klick.service | awk '/pid =/ {print $3}')"
kill -9 "$pid"
check "launchd перезапустил службу, VPN вернулся" wait_for 30 state_is connected
check "ядро от упавшей службы не осталось" test "$(pgrep -f '/Library/PrivilegedHelperTools/klick/mihomo' | wc -l | tr -d ' ')" = "1"
check "прокси на месте" proxy_on
cli disconnect >/dev/null

if [[ $failed -gt 0 ]]; then
    echo "--- журнал службы"
    tail -120 "$log" 2>/dev/null
fi

echo "== удаление"
"$svc" uninstall --wipe
check "служба убрана из launchd" bash -c '! launchctl print system/app.klick.service'
check "файлы службы удалены" test ! -e /Library/PrivilegedHelperTools/klick
check "прокси не остался" bash -c '! scutil --proxy | grep -q "HTTPPort : 7890"'
check "DNS не остался" bash -c '! scutil --dns | grep -q "198.18.0.2"'

if [[ $failed -gt 0 ]]; then
    echo "== не прошло проверок: $failed"
    exit 1
fi
echo "== все проверки прошли"
