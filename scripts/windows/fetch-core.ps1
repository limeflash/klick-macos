# Downloads the mihomo core for Windows into resources\core\mihomo.exe: the official MetaCubeX release,
# the exact build listed in README (SHA-256 of the exe). Several release variants are tried; only the
# file whose SHA-256 matches is kept, so a substituted or broken core never gets into the build.
#   powershell -ExecutionPolicy Bypass -File scripts\windows\fetch-core.ps1 [-Force]
# (ASCII only: Windows PowerShell 5.1 reads BOM-less scripts in the ANSI code page.)
param([switch]$Force)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$Version = 'v1.19.31'
# README: mihomo.exe (v1.19.31, windows amd64, with_gvisor)
$ExeSha256 = '1fa8055e03596fc35167f70e9ecd1890517d38d960a39177445746a1b0defc2b'
$Variants = @('amd64-compatible', 'amd64', 'amd64-v1', 'amd64-v2', 'amd64-v3')

$root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$out = Join-Path $root 'resources\core\mihomo.exe'
if ((Test-Path $out) -and -not $Force) {
    $have = (Get-FileHash -Algorithm SHA256 $out).Hash.ToLower()
    if ($have -eq $ExeSha256) { Write-Host "already there: $out"; return }
}

$tmp = Join-Path ([IO.Path]::GetTempPath()) ('klick-core-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force $tmp | Out-Null
try {
    foreach ($v in $Variants) {
        $zip = Join-Path $tmp "mihomo-windows-$v.zip"
        $url = "https://github.com/MetaCubeX/mihomo/releases/download/$Version/mihomo-windows-$v-$Version.zip"
        try { Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $zip } catch { Write-Host "no $url"; continue }
        $dir = Join-Path $tmp $v
        Expand-Archive -Force $zip $dir
        $exe = Get-ChildItem $dir -Filter '*.exe' | Select-Object -First 1
        $sha = (Get-FileHash -Algorithm SHA256 $exe.FullName).Hash.ToLower()
        Write-Host "$($exe.Name): $sha"
        if ($sha -eq $ExeSha256) {
            New-Item -ItemType Directory -Force (Split-Path $out) | Out-Null
            Copy-Item $exe.FullName $out -Force
            & $out -v
            Write-Host "ok: $out ($v)"
            return
        }
    }
    throw "no $Version build matches SHA-256 $ExeSha256"
}
finally {
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}
