# CI (GitHub Actions, Windows runner): the same checks as in Windows Sandbox, on the runner itself,
# which is a fresh VM too. Stages the build into C:\klick like sandbox\start.ps1, runs one scenario in
# Windows PowerShell 5.1 (as in the Sandbox), prints its report and fails when the report has failures.
#   pwsh -File sandbox\ci.ps1 -Scenario run|setup|ks-browser|real -Build <folder> [-Old <kl!ck 0.3.0 NSIS setup>]
# <folder>: klick-service.exe, klick-cli.exe, klick.exe, klick-setup.exe and resources\ (with core\mihomo.exe).
# real: the subscription link comes in KLICK_TEST_SUB.
param(
    [Parameter(Mandatory)][ValidateSet('run', 'setup', 'ks-browser', 'real')][string]$Scenario,
    [Parameter(Mandatory)][string]$Build,
    [string]$Old
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$root = 'C:\klick'
if (Test-Path $root) { Remove-Item $root -Recurse -Force }
New-Item -ItemType Directory -Force "$root\bin", "$root\results" | Out-Null
Copy-Item "$Build\klick-service.exe", "$Build\klick-cli.exe", "$Build\klick.exe" "$root\bin"
Copy-Item "$Build\klick-setup.exe" "$root\klick-setup.exe"
Copy-Item "$Build\resources" "$root\resources" -Recurse
# Windows PowerShell 5.1 reads a script as UTF-8 only when it has a BOM.
foreach ($s in 'run.ps1', 'setup-test.ps1', 'ks-browser.ps1', 'real-test.ps1') {
    $text = [IO.File]::ReadAllText("$PSScriptRoot\$s", [Text.Encoding]::UTF8)
    [IO.File]::WriteAllText("$root\$s", $text, (New-Object Text.UTF8Encoding $true))
}
if ($Scenario -eq 'ks-browser') {
    Copy-Item "$PSScriptRoot\ks-browser.mjs" "$root\ks-browser.mjs"
    New-Item -ItemType Directory -Force "$root\node" | Out-Null
    Copy-Item (Get-Command node.exe).Source "$root\node\node.exe"
}
if ($Old) { Copy-Item $Old "$root\old-nsis.exe" }

$plan = @{
    'run'        = @('run.ps1', @('report.txt'), 'ИТОГ: провалов (\d+)')
    'setup'      = @('setup-test.ps1', @('setup-report.txt', 'report.txt'), 'ИТОГ УСТАНОВЩИКА: провалов (\d+)')
    'ks-browser' = @('ks-browser.ps1', @('ks-browser.txt'), 'ИТОГ: шагов \d+, провалов (\d+)')
    'real'       = @('real-test.ps1', @('real-report.txt'), 'ИТОГ: провалов (\d+)')
}[$Scenario]
$entry, $reports, $summary = $plan

Write-Host "== $Scenario ($entry) on $((Get-CimInstance Win32_OperatingSystem).Caption) $([Environment]::OSVersion.Version)"
$ErrorActionPreference = 'Continue'
& "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "$root\$entry" -NoShutdown *> "$root\results\run.out"

foreach ($r in $reports) {
    $f = "$root\results\$r"
    if (Test-Path $f) { Write-Host "===== $r"; Get-Content $f -Encoding UTF8 | ForEach-Object { Write-Host $_ } }
}
$main = "$root\results\$($reports[0])"
$sum = if (Test-Path $main) { Get-Content $main -Encoding UTF8 | Select-String $summary | Select-Object -Last 1 } else { $null }
$fails = if ($sum) { [int]$sum.Matches[0].Groups[1].Value } else { -1 }
if ($fails -ne 0) {
    Write-Host '===== script output'
    Get-Content "$root\results\run.out" -ErrorAction SilentlyContinue | Select-Object -Last 40 | ForEach-Object { Write-Host $_ }
    $log = if (Test-Path "$root\results\service.log") { "$root\results\service.log" } else { 'C:\ProgramData\klick\logs\service.log' }
    Write-Host "===== service log ($log)"
    Get-Content $log -Encoding UTF8 -ErrorAction SilentlyContinue | Select-Object -Last 120 | ForEach-Object { Write-Host $_ }
}
if ($fails -lt 0) { Write-Host "== no summary in $($reports[0])"; exit 1 }
Write-Host "== $Scenario`: failures $fails"
exit ([int]($fails -gt 0))
