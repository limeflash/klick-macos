#!/bin/bash
# Проверка kl!ck на настоящем Mac с настоящей подпиской: серверы, задержка, прокси и TUN «всё через VPN»
# (адрес выхода, UDP), смена сервера, Kill Switch с удалённым сервером. Меняет настройки сети Mac и в конце
# возвращает их — запускать на тестовой машине или в CI, а не на рабочем компьютере.
#
#   sudo KLICK_TEST_SUB='https://…' scripts/macos/real-test.sh 'dist/kl!ck.app'
#
# Ссылка подписки и адреса в журнал не пишутся: только страны, провайдеры и «совпало / не совпало».
set -uo pipefail

[[ $EUID -eq 0 ]] || { echo "нужен root: sudo KLICK_TEST_SUB=… $0 $*" >&2; exit 2; }
[[ -n "${KLICK_TEST_SUB:-}" ]] || { echo "нет KLICK_TEST_SUB — ссылки подписки" >&2; exit 2; }
app="${1:-dist/kl!ck.app}"
[[ -x "$app/Contents/MacOS/klick-service" ]] || { echo "нет $app" >&2; exit 2; }
app="$(cd "$(dirname "$app")" && pwd)/$(basename "$app")"

svc="/Library/PrivilegedHelperTools/klick/klick-service"
cli() { "$app/Contents/MacOS/klick-cli" --prod "$@"; }
log="/Library/Application Support/klick/logs/service.log"
tmp="$(mktemp -d)"
failed=0

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
json() { /usr/bin/python3 -c "import json,sys; d=json.load(sys.stdin); $1"; }

# Всё, что «как у человека», — от имени пользователя: root правило pf Kill Switch пропускает.
user="${SUDO_USER:-nobody}"
[[ "$user" == "root" ]] && user=nobody
as_user() { sudo -u "$user" "$@"; }
ks="/Users/Shared/klick-ks/tool/kscurl"

# Адрес выхода по TCP: два независимых сервиса, первый ответивший.
ip_via() { # ip_via программа [аргументы curl…]
    local bin="$1"; shift
    local u
    for u in https://api.ipify.org https://ipv4.icanhazip.com; do
        local ip
        ip="$(as_user "$bin" -4 -s -m 10 "$@" "$u" 2>/dev/null | tr -d '[:space:]')"
        [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && { echo "$ip"; return 0; }
    done
    return 1
}
# Адрес выхода по UDP: запрос STUN (так его видят звонки и игры).
udp_ip() {
    as_user /usr/bin/python3 - <<'PY'
import os, socket, struct, sys
req = struct.pack('!HHI', 1, 0, 0x2112A442) + os.urandom(12)
for host, port in (('stun.l.google.com', 19302), ('stun.cloudflare.com', 3478)):
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.settimeout(5)
        s.sendto(req, (host, port))
        data, _ = s.recvfrom(2048)
    except OSError:
        continue
    i = 20
    while i + 4 <= len(data):
        t, l = struct.unpack('!HH', data[i:i + 4])
        v = data[i + 4:i + 4 + l]
        if t == 0x0020 and v[1] == 1:
            ip = struct.unpack('!I', v[4:8])[0] ^ 0x2112A442
            print(socket.inet_ntoa(struct.pack('!I', ip)))
            sys.exit(0)
        i += 4 + l + (-l % 4)
sys.exit(1)
PY
}
# Адрес из сети Mac. Сеть, а не один адрес: провайдер (и раннер GitHub) может выпускать соединения
# с разных адресов одного пула (…117.214, …117.215), а адрес сервера VPN из другой сети.
is_direct() { [[ -n "$1" && "${1%.*}" == "${direct%.*}" ]]; }
# Защищённая программа ни разу не вышла в интернет напрямую за столько-то секунд.
ks_never_direct() {
    local end=$((SECONDS + $1)) ip
    while (( SECONDS < end )); do
        ip="$(as_user "$ks" -4 -s -m 2 https://api.ipify.org 2>/dev/null | tr -d '[:space:]')"
        if is_direct "$ip"; then
            echo "    защищённая программа вышла напрямую на $((SECONDS - end + $1))-й секунде" >&2
            return 1
        fi
        sleep 0.2
    done
}
ks_via_vpn() { local ip; ip="$(ip_via "$ks")" && ! is_direct "$ip"; }
ks_direct_ok() { is_direct "$(ip_via "$ks")"; }
ks_direct_blocked() { ! as_user "$ks" -4 -s -o /dev/null -m 5 https://api.ipify.org; }
# Скачать 20 МБ и напечатать скорость — для сведения: сервис замера может ограничивать адреса дата-центров.
speed() { # speed [аргументы curl…]
    local out
    out="$(as_user /usr/bin/curl -4 -s -o /dev/null -m 60 -w '%{http_code} %{speed_download}' "$@" \
        'https://speed.cloudflare.com/__down?bytes=20000000')"
    if [[ "${out%% *}" == "200" ]]; then
        awk -v b="${out#* }" 'BEGIN { printf "    скорость: %.1f Мбит/с\n", b * 8 / 1000000 }'
    else
        echo "    скорость: не измерена (${out:-нет ответа})"
    fi
}
where() { # where ipcheck-колонка
    cli ip | json "c = d.get('$1') or {}; print('    ' + ', '.join(str(x) for x in (c.get('country'), c.get('city'), c.get('provider')) if x) + ('  (ошибка: %s)' % c['error'] if c.get('error') else ''))"
}

cleanup() {
    echo "== уборка"
    [[ -x "$svc" ]] && "$svc" uninstall --wipe >/dev/null 2>&1
    rm -rf /Users/Shared/klick-ks "$tmp"
}
trap cleanup EXIT

echo "== $(sw_vers -productName) $(sw_vers -productVersion) $(uname -m), проверки от имени $user"
direct="$(ip_via /usr/bin/curl)" || { echo "нет интернета у Mac"; exit 1; }
direct_udp="$(udp_ip)" || direct_udp=""
[[ -n "$direct_udp" ]] && pass "STUN отвечает напрямую" || echo "    STUN напрямую не отвечает — проверка UDP через VPN пропущена"

echo "== установка службы"
"$app/Contents/MacOS/klick-service" install || { echo "install не удался"; exit 1; }
check "служба отвечает" wait_for 20 cli status

echo "== подписка"
cli add "$KLICK_TEST_SUB" > "$tmp/add.json" 2>&1 && pass "подписка добавлена" || { fail "подписка добавлена"; head -c 300 "$tmp/add.json" | sed -E 's#https?://[^" ]+#<ссылка>#g'; echo; }
json "print('    ' + d['name'], '·', 'истекает' if d.get('info', {}).get('expire') else 'без срока')" < "$tmp/add.json" 2>/dev/null
rm -f "$tmp/add.json"
cli servers | json "print('    серверов: %d · %s' % (len(d), ', '.join(sorted({s['kind'] for s in d}))))"
cli latency > "$tmp/lat.json"
json "print('\n'.join('    %-24s %s' % (s['name'], '%d мс' % s['delay'] if s['delay'] else 'нет ответа') for s in d))" < "$tmp/lat.json"
json "sys.exit(0 if any(s['delay'] for s in d) else 1)" < "$tmp/lat.json" && pass "задержка измерена хотя бы у одного" || fail "задержка измерена хотя бы у одного"
fast=()
while IFS= read -r name; do [[ -n "$name" ]] && fast+=("$name"); done \
    < <(json "print('\n'.join(s['name'] for s in sorted((s for s in d if s['delay']), key=lambda s: s['delay'])))" < "$tmp/lat.json" 2>/dev/null)
rm -f "$tmp/lat.json"
if [[ ${#fast[@]} -eq 0 ]]; then
    echo "== ни один сервер не ответил — дальше проверять нечего"
    tail -60 "$log" 2>/dev/null | sed -E 's#https?://[^" ]+#<ссылка>#g'
    exit 1
fi
check "выбран самый быстрый: ${fast[0]}" cli server "${fast[0]}"

echo "== режим «Системный прокси», всё через VPN"
cli routing all >/dev/null
cli mode proxy >/dev/null
cli connect >/dev/null
check "подключено" wait_for 30 state_is connected
vpn="$(ip_via /usr/bin/curl -x http://127.0.0.1:7890)" && ! is_direct "$vpn" \
    && pass "через прокси адрес выхода — сервера, не Mac" || fail "через прокси адрес выхода — сервера, не Mac"
where via_vpn
speed -x http://127.0.0.1:7890
cli disconnect >/dev/null
check "выключено" wait_for 10 state_is off

echo "== режим VPN (TUN), всё через VPN"
cli mode tun >/dev/null
cli connect >/dev/null
check "подключено" wait_for 30 state_is connected
vpn="$(ip_via /usr/bin/curl)" && ! is_direct "$vpn" \
    && pass "адрес выхода по TCP — сервера" || fail "адрес выхода по TCP — сервера"
if [[ -n "$direct_udp" ]]; then
    u="$(udp_ip)" && [[ "${u%.*}" != "${direct_udp%.*}" ]] && pass "UDP идёт через VPN (STUN видит сервер)" || fail "UDP идёт через VPN (STUN видит сервер)"
fi
report="$(cli ip)"
json "c = d.get('via_vpn') or {}; print('    ' + ', '.join(str(x) for x in (c.get('country'), c.get('city'), c.get('provider')) if x))" <<< "$report"
json "print('    утечка IPv6:', d.get('ipv6_leak'))" <<< "$report"
json "sys.exit(0 if d.get('dns_protected') else 1)" <<< "$report" && pass "DNS отвечает kl!ck" || fail "DNS отвечает kl!ck"
speed
if [[ ${#fast[@]} -gt 1 ]]; then
    check "смена сервера на ходу: ${fast[1]}" cli server "${fast[1]}"
    check "после смены сервера всё ещё подключено" wait_for 20 state_is connected
    check "после смены сервера страницы открываются" wait_for 20 ip_via /usr/bin/curl
    where via_vpn
    cli server "${fast[0]}" >/dev/null
fi
cli disconnect >/dev/null
check "адаптер убран" wait_for 10 bash -c '! ifconfig | grep -q "inet 198.18.0.1 "'
now="$(ip_via /usr/bin/curl)" && is_direct "$now" && pass "после отключения адрес снова свой" || fail "после отключения адрес снова свой"

echo "== Kill Switch с настоящим сервером (положение «только выбранное»)"
mkdir -p /Users/Shared/klick-ks/tool
cp /usr/bin/curl "$ks"
chmod 755 /Users/Shared/klick-ks /Users/Shared/klick-ks/tool "$ks"
cli routing selected >/dev/null
check "добавить программу в Kill Switch" cli ks add /Users/Shared/klick-ks/tool
check "VPN выключен — защищённая программа не выходит" wait_for 15 ks_direct_blocked
cli connect >/dev/null
check "VPN подключён" wait_for 30 state_is connected
check "защищённая программа ходит через VPN" wait_for 30 ks_via_vpn
now="$(ip_via /usr/bin/curl)" && is_direct "$now" && pass "остальные ходят напрямую" || fail "остальные ходят напрямую"
kill -9 "$(cat /var/run/klick/core.sock.pid)"
check "упало ядро — защищённая программа не вышла напрямую" ks_never_direct 10
check "ядро вернулось, защищённая программа снова через VPN" wait_for 60 ks_via_vpn
kill -9 "$(launchctl print system/app.klick.service | awk '/pid =/ {print $3}')"
check "упала служба — защищённая программа не вышла напрямую" ks_never_direct 10
check "служба вернулась, защищённая программа снова через VPN" wait_for 60 ks_via_vpn
cli disconnect >/dev/null
check "VPN выключен — защищённая программа не вышла напрямую" ks_never_direct 5
check "убрать из Kill Switch" cli ks rm /Users/Shared/klick-ks/tool
check "программа снова ходит напрямую" wait_for 15 ks_direct_ok

if [[ $failed -gt 0 ]]; then
    echo "--- журнал службы"
    tail -150 "$log" 2>/dev/null | sed -E 's#https?://[^" ]+#<ссылка>#g'
fi

echo "== удаление"
"$svc" uninstall --wipe
check "прокси не остался" bash -c '! scutil --proxy | grep -q "HTTPPort : 7890"'
check "DNS не остался" bash -c '! scutil --dns | grep -q "198.18.0.2"'
check "правил pf не осталось" bash -c '! pfctl -a com.apple/090.klick -s rules 2>/dev/null | grep -q block'
now="$(ip_via /usr/bin/curl)" && is_direct "$now" && pass "интернет у пользователя свой" || fail "интернет у пользователя свой"

if [[ $failed -gt 0 ]]; then
    echo "== не прошло проверок: $failed"
    exit 1
fi
echo "== все проверки прошли"
