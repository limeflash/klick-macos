# Проверка kl!ck с настоящими серверами из подписки — на раннере CI (sandbox\ci.ps1) или тестовом компьютере.
# Ссылка подписки — в переменной KLICK_TEST_SUB, в отчёт она не пишется. kl!ck ставится установщиком,
# в конце удаляется вместе с данными. Сценарии: прокси и VPN (TUN) «всё через VPN», UDP, DNS, смена сервера,
# сеть без зашифрованного DNS, Kill Switch со сбоями ядра и службы, скорость «Отключить», удаление.
# Меняет настройки сети — только на тестовой машине.
param([switch]$NoShutdown)

$ErrorActionPreference = 'Continue'
$root = 'C:\klick'
$out = Join-Path $root 'results'
$inst = 'C:\Program Files\klick'
New-Item -ItemType Directory -Force $out | Out-Null
$report = Join-Path $out 'real-report.txt'
Set-Content -Path $report -Value '' -Encoding UTF8
$script:fails = 0
$sub = $env:KLICK_TEST_SUB

function Log([string]$m) { Add-Content -Path $report -Value ("[{0:HH:mm:ss}] {1}" -f (Get-Date), $m) -Encoding UTF8 }
function Check([string]$name, [bool]$ok, [string]$detail = '') {
    if (-not $ok) { $script:fails++ }
    $mark = if ($ok) { 'OK  ' } else { 'FAIL' }
    $tail = if ($detail) { " - $detail" } else { '' }
    Log "$mark $name$tail"
}
function KlickCli { (& "$inst\klick-cli.exe" --prod @args 2>&1 | Out-String).Trim() }
function KlickJson { $t = & "$inst\klick-cli.exe" --prod @args 2>$null | Out-String; try { $t | ConvertFrom-Json | ForEach-Object { $_ } } catch { $null } }
function WaitVpn([string]$want, [int]$seconds) {
    $end = (Get-Date).AddSeconds($seconds)
    do { $s = KlickJson status; if ($s.vpn -eq $want) { return $s }; Start-Sleep 1 } while ((Get-Date) -lt $end)
    return $s
}
function Http([string]$exe = 'curl.exe', [string]$url = 'https://www.gstatic.com/generate_204', [string[]]$extra = @()) {
    $code = & $exe -s -o NUL -w '%{http_code}' --max-time 12 @extra $url 2>$null
    if ($code) { "$code".Trim() } else { '000' }
}
# Адрес выхода по TCP: два независимых сервиса, первый ответивший.
function IpVia([string]$exe = 'curl.exe', [string[]]$extra = @(), [int]$timeout = 10) {
    foreach ($u in 'https://api.ipify.org', 'https://ipv4.icanhazip.com') {
        $r = (& $exe -4 -s --max-time $timeout @extra $u 2>$null | Out-String).Trim()
        if ($r -match '^\d+\.\d+\.\d+\.\d+$') { return $r }
    }
    return ''
}
# Адрес раннера в NAT облака меняется в пределах /24 — прямым считаем любой адрес из той же /24.
function Net24([string]$ip) { if ($ip) { $ip.Substring(0, $ip.LastIndexOf('.')) } else { '' } }
function IsDirect([string]$ip) { [bool]$ip -and (Net24 $ip) -eq (Net24 $script:direct) }
function Speed([string[]]$extra = @()) {
    $bps = & curl.exe -s -o NUL --max-time 20 -w '%{speed_download}' @extra 'https://speed.cloudflare.com/__down?bytes=25000000' 2>$null
    $v = 0.0
    if ([double]::TryParse("$bps".Trim().Replace(',', '.'), [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$v)) {
        Log ("    скорость: {0:N1} Мбит/с" -f ($v * 8 / 1e6))
    }
}
# Адрес выхода по UDP: запрос STUN (так его видят звонки и игры). Нужен Python; без него — пусто.
$stun = @'
import os, socket, struct, sys
req = struct.pack('!HHI', 1, 0, 0x2112A442) + os.urandom(12)
for host, port in (('stun.l.google.com', 19302), ('stun.cloudflare.com', 3478)):
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.settimeout(3)
        s.sendto(req, (host, port))
        data = s.recv(2048)
        i = 20
        while i + 4 <= len(data):
            t, l = struct.unpack('!HH', data[i:i + 4])
            v = data[i + 4:i + 4 + l]
            if t in (0x0020, 0x0001) and len(v) >= 8:
                ip = bytes(v[4:8])
                if t == 0x0020:
                    ip = bytes(a ^ b for a, b in zip(ip, struct.pack('!I', 0x2112A442)))
                print('.'.join(map(str, ip)))
                sys.exit(0)
            i += 4 + l + (-l % 4)
    except Exception:
        pass
sys.exit(1)
'@
Set-Content "$out\stun.py" $stun -Encoding ASCII
$python = (Get-Command python.exe -ErrorAction SilentlyContinue).Source
function UdpIp { if ($python) { (& $python "$out\stun.py" 2>$null | Out-String).Trim() } else { '' } }
# Отключить и замерить: «Отключить» должно срабатывать сразу, а не через секунды.
function DisconnectTimed([string]$what) {
    $t = Measure-Command { KlickCli disconnect | Out-Null }
    $line = Get-Content 'C:\ProgramData\klick\logs\service.log' -Encoding UTF8 -ErrorAction SilentlyContinue | Select-String 'отключено за' | Select-Object -Last 1
    Log ("    «Отключить» ({0}): {1:N3} с {2}" -f $what, $t.TotalSeconds, $(if ($line) { '; ' + ($line.Line -replace '.*отключено', 'отключено') } else { '' }))
    Check "«Отключить» ($what) быстрее 2 с" ($t.TotalSeconds -le 2) ("{0:N3} с" -f $t.TotalSeconds)
}
# Программа из Kill Switch ни разу не вышла в интернет напрямую за столько-то секунд.
function KsNeverDirect([int]$seconds) {
    $end = (Get-Date).AddSeconds($seconds)
    while ((Get-Date) -lt $end) {
        $ip = (& 'C:\kstest\curl.exe' -4 -s --max-time 2 'https://api.ipify.org' 2>$null | Out-String).Trim()
        if ($ip -match '^\d+\.\d+\.\d+\.\d+$' -and (IsDirect $ip)) { Log "    программа из Kill Switch вышла напрямую: $ip"; return $false }
        Start-Sleep -Milliseconds 200
    }
    return $true
}
function KsViaVpn { $ip = IpVia 'C:\kstest\curl.exe'; [bool]$ip -and -not (IsDirect $ip) }
function ProxyReg { Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' }
function CoreProc { Get-CimInstance Win32_Process -Filter "Name='mihomo.exe'" | Where-Object { $_.CommandLine -like '*ProgramData*' -and $_.CommandLine -notlike '*tester*' } }

try {
    if (-not $sub) { throw 'нет KLICK_TEST_SUB' }
    Log ("Windows {0}, {1}" -f [Environment]::OSVersion.Version, (Get-CimInstance Win32_OperatingSystem).Caption)
    $script:direct = IpVia
    Check 'интернет напрямую есть' ([bool]$script:direct) $script:direct
    $directUdp = UdpIp
    Log "    STUN напрямую: $(if ($directUdp) { 'отвечает' } else { 'нет ответа или нет Python' })"

    # 1. Установка установщиком, как у человека
    $p = Start-Process "$root\klick-setup.exe" -ArgumentList '--silent', '--no-autostart' -Wait -PassThru -WindowStyle Hidden
    Check 'установка: код 0' ($p.ExitCode -eq 0) "код $($p.ExitCode)"
    Copy-Item "$root\bin\klick-cli.exe" $inst -Force
    $end = (Get-Date).AddSeconds(20)
    while (-not (KlickJson status) -and (Get-Date) -lt $end) { Start-Sleep 1 }
    Check 'служба отвечает' ($null -ne (KlickJson status))

    # 2. Подписка, серверы, задержка
    $added = KlickCli add $sub
    Check 'подписка добавлена' ($LASTEXITCODE -eq 0 -and $added -notmatch 'error|ошибк') (($added -replace [regex]::Escape($sub), '<ссылка>') -split "`n" | Select-Object -First 1)
    $servers = @(KlickJson servers)
    Log ("    серверов: {0} · {1}" -f $servers.Count, ((@($servers | ForEach-Object { $_.kind }) | Sort-Object -Unique) -join ', '))
    $lat = @(KlickJson latency)
    foreach ($s in $lat) { Log ("    {0,-24} {1}" -f $s.name, $(if ($s.delay) { "$($s.delay) мс" } else { 'нет ответа' })) }
    $fast = @($lat | Where-Object { $_.delay -gt 0 } | Sort-Object delay | ForEach-Object { $_.name })
    Check 'задержка измерена хотя бы у одного' ($fast.Count -gt 0)
    if ($fast.Count -eq 0) { throw 'ни один сервер не ответил — дальше проверять нечего' }
    $sel = KlickCli server $fast[0]
    Check "выбран самый быстрый: $($fast[0])" ($LASTEXITCODE -eq 0) $sel

    # 3. «Системный прокси», всё через VPN
    KlickCli routing all | Out-Null
    KlickCli mode proxy | Out-Null
    KlickCli connect | Out-Null
    $st = WaitVpn 'connected' 30
    Check 'прокси: подключено' ($st.vpn -eq 'connected') ("vpn=" + $st.vpn)
    $vpn = IpVia 'curl.exe' @('-x', 'http://127.0.0.1:7890')
    Check 'через порт 7890 адрес выхода — сервера, не компьютера' ([bool]$vpn -and -not (IsDirect $vpn))
    $reg = ProxyReg
    Check 'системный прокси поставлен' ($reg.ProxyEnable -eq 1 -and $reg.ProxyServer -eq '127.0.0.1:7890') ("ProxyEnable={0}, ProxyServer={1}" -f $reg.ProxyEnable, $reg.ProxyServer)
    Speed @('-x', 'http://127.0.0.1:7890')
    DisconnectTimed 'Системный прокси'
    $st = KlickJson status
    Check 'прокси: выключено' ($st.vpn -eq 'off') ("vpn=" + $st.vpn)
    $reg = ProxyReg
    Check 'системный прокси снят' ($reg.ProxyEnable -eq 0) ("ProxyEnable=" + $reg.ProxyEnable)

    # 4. VPN (TUN), всё через VPN
    KlickCli mode tun | Out-Null
    KlickCli connect | Out-Null
    $st = WaitVpn 'connected' 30
    Check 'TUN: подключено' ($st.vpn -eq 'connected') ("vpn=" + $st.vpn)
    Check 'адаптер klick поднят' ([bool](Get-NetAdapter -Name klick -ErrorAction SilentlyContinue | Where-Object Status -eq 'Up'))
    $vpn = IpVia
    Check 'адрес выхода по TCP — сервера' ([bool]$vpn -and -not (IsDirect $vpn))
    if ($directUdp) {
        $u = UdpIp
        Check 'UDP идёт через VPN (STUN видит сервер)' ([bool]$u -and (Net24 $u) -ne (Net24 $directUdp))
    }
    $rep = KlickJson ip
    if ($rep.via_vpn) { Log ("    {0}, {1}, {2}" -f $rep.via_vpn.country, $rep.via_vpn.city, $rep.via_vpn.provider) }
    Check 'DNS отвечает kl!ck' ($rep.dns_protected -eq $true)
    Check 'IPv6 не уходит мимо туннеля' ($rep.ipv6_leak -ne $true) ("ipv6_leak=" + $rep.ipv6_leak)
    Speed
    if ($fast.Count -gt 1) {
        $sw = KlickCli server $fast[1]
        Check "смена сервера на ходу: $($fast[1])" ($LASTEXITCODE -eq 0) $sw
        $st = WaitVpn 'connected' 20
        Check 'после смены сервера всё ещё подключено' ($st.vpn -eq 'connected')
        $ok = $false; $end = (Get-Date).AddSeconds(20)
        while (-not $ok -and (Get-Date) -lt $end) { $ok = [bool](IpVia); if (-not $ok) { Start-Sleep 1 } }
        Check 'после смены сервера страницы открываются' $ok
        KlickCli server $fast[0] | Out-Null
    }
    DisconnectTimed 'VPN (TUN)'
    Start-Sleep 1
    Check 'адаптер убран' (-not (Get-NetAdapter -Name klick -ErrorAction SilentlyContinue))
    $now = IpVia
    Check 'после отключения адрес снова свой' (IsDirect $now)

    # 5. Сеть, где зашифрованный DNS (DoH Cloudflare и Яндекса) не работает: адреса серверов kl!ck
    #    должен найти через DNS системы.
    foreach ($proto in 'TCP', 'UDP') {
        New-NetFirewallRule -DisplayName "klick-test-doh-$proto" -Direction Outbound -Action Block -Protocol $proto -RemoteAddress 1.1.1.1, 1.0.0.1, 77.88.8.8, 77.88.8.1 -RemotePort 443, 853 | Out-Null
    }
    $doh = (Http 'curl.exe' 'https://1.1.1.1/dns-query') + '/' + (Http 'curl.exe' 'https://77.88.8.8/dns-query')
    Check 'DoH Cloudflare и Яндекса действительно недоступен' ($doh -eq '000/000') $doh
    KlickCli connect | Out-Null
    $st = WaitVpn 'connected' 30
    Check 'подключено без зашифрованного DNS' ($st.vpn -eq 'connected') ("vpn=" + $st.vpn)
    $vpn = IpVia
    Check 'без зашифрованного DNS адрес выхода — сервера' ([bool]$vpn -and -not (IsDirect $vpn))
    KlickCli disconnect | Out-Null
    Get-NetFirewallRule -DisplayName 'klick-test-doh-*' -ErrorAction SilentlyContinue | Remove-NetFirewallRule

    # 6. Kill Switch с настоящим сервером, положение «только выбранное»
    New-Item -ItemType Directory -Force 'C:\kstest' | Out-Null
    Copy-Item "$env:WINDIR\System32\curl.exe" 'C:\kstest\curl.exe' -Force
    KlickCli routing selected | Out-Null
    Log ("ks add: " + ((KlickCli ks add 'C:\kstest') -replace '\s+', ' '))
    Start-Sleep 2
    Check 'VPN выключен — программа из Kill Switch без сети' ((Http 'C:\kstest\curl.exe') -eq '000')
    KlickCli connect | Out-Null
    $st = WaitVpn 'connected' 30
    Check 'Kill Switch: VPN подключён' ($st.vpn -eq 'connected')
    $ok = $false; $end = (Get-Date).AddSeconds(30)
    while (-not $ok -and (Get-Date) -lt $end) { $ok = KsViaVpn; if (-not $ok) { Start-Sleep 1 } }
    Check 'программа из Kill Switch ходит через VPN' $ok
    Check 'остальные ходят напрямую' (IsDirect (IpVia))
    $core = CoreProc | Select-Object -First 1
    if ($core) { Stop-Process -Id $core.ProcessId -Force }
    Check 'упало ядро — программа из Kill Switch не вышла напрямую' (KsNeverDirect 10)
    $ok = $false; $end = (Get-Date).AddSeconds(60)
    while (-not $ok -and (Get-Date) -lt $end) { $ok = KsViaVpn; if (-not $ok) { Start-Sleep 1 } }
    Check 'ядро вернулось, программа снова через VPN' $ok
    $svcProc = Get-Process klick-service -ErrorAction SilentlyContinue
    if ($svcProc) { Stop-Process -Id $svcProc.Id -Force }
    Check 'упала служба — программа из Kill Switch не вышла напрямую' (KsNeverDirect 10)
    $ok = $false; $end = (Get-Date).AddSeconds(60)
    while (-not $ok -and (Get-Date) -lt $end) { $ok = KsViaVpn; if (-not $ok) { Start-Sleep 1 } }
    Check 'служба вернулась, программа снова через VPN' $ok
    DisconnectTimed 'Kill Switch включён'
    Check 'VPN выключен — программа из Kill Switch не вышла напрямую' (KsNeverDirect 5)
    KlickCli ks rm 'C:\kstest' | Out-Null
    $ok = $false; $end = (Get-Date).AddSeconds(15)
    while (-not $ok -and (Get-Date) -lt $end) { $ok = (Http 'C:\kstest\curl.exe') -eq '204'; if (-not $ok) { Start-Sleep 1 } }
    Check 'убрана из Kill Switch — снова ходит напрямую' $ok

    # 7. Удаление вместе с данными (журнал службы — до удаления: с данными уйдёт и он)
    Copy-Item 'C:\ProgramData\klick\logs\service.log' "$out\service.log" -ErrorAction SilentlyContinue
    KlickCli mode proxy | Out-Null
    KlickCli connect | Out-Null
    WaitVpn 'connected' 30 | Out-Null
    $p = Start-Process "$root\klick-setup.exe" -ArgumentList '--silent', '--uninstall', '--wipe' -Wait -PassThru -WindowStyle Hidden
    Check 'удаление при включённом VPN: код 0' ($p.ExitCode -eq 0) "код $($p.ExitCode)"
    Check 'служба удалена' (-not (Get-Service klick -ErrorAction SilentlyContinue))
    Check 'ядро остановлено' (-not (Get-Process mihomo -ErrorAction SilentlyContinue))
    $reg = ProxyReg
    Check 'системного прокси kl!ck не осталось' (-not ($reg.ProxyEnable -eq 1 -and $reg.ProxyServer -eq '127.0.0.1:7890')) ("ProxyEnable={0}, ProxyServer={1}" -f $reg.ProxyEnable, $reg.ProxyServer)
    Check 'адаптера не осталось' (-not (Get-NetAdapter -Name klick -ErrorAction SilentlyContinue))
    Check 'интернет свой' (IsDirect (IpVia))
    Check 'программа из бывшего Kill Switch в сети' ((Http 'C:\kstest\curl.exe') -eq '204')
}
catch {
    $script:fails++
    Log "ОШИБКА СЦЕНАРИЯ: $($_.Exception.Message)"
}
finally {
    Get-NetFirewallRule -DisplayName 'klick-test-doh-*' -ErrorAction SilentlyContinue | Remove-NetFirewallRule
    Log ("ИТОГ: провалов {0}" -f $script:fails)
    Copy-Item 'C:\ProgramData\klick\logs\service.log' "$out\service.log" -ErrorAction SilentlyContinue
    Set-Content "$out\real-done.txt" 'done'
    if (-not $NoShutdown) {
        Start-Sleep 2
        shutdown.exe /s /t 0
    }
}
