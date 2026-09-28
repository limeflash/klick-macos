#!/bin/bash
# Скачивает ядро mihomo для macOS (arm64 и x86_64), сверяет SHA-256 и кладёт универсальный файл
# в resources/core/mihomo. Нужен для сборки и для службы в режиме разработки.
# Версия — та же, что у Windows-сборки (resources/core/mihomo.exe).
#
#   scripts/macos/fetch-core.sh           # универсальный (lipo), на Linux — под текущую архитектуру
#   scripts/macos/fetch-core.sh --force   # скачать заново
set -euo pipefail

VERSION="v1.19.31"
# SHA-256 архивов .gz с https://github.com/MetaCubeX/mihomo/releases/tag/v1.19.31
SHA_ARM64="d131f44b3deb2a8356f7ac75048ad67a10d53243323951c4f3cda7b672922963"
SHA_AMD64="3546681ebef3415e5dcbe7210a61aa80748136e95e6552768fd883df345508ed"
SHA_LINUX_AMD64="d5e74bbddbdfff49a1aef7775bf5911da59f0d7196ed509a0ac914b3653dd5f1"

root="$(cd "$(dirname "$0")/../.." && pwd)"
out="$root/resources/core/mihomo"
if [[ -x "$out" && "${1:-}" != "--force" ]]; then
    echo "уже есть: $out ($("$out" -v 2>/dev/null | head -1 || echo '?'))"
    exit 0
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

sha256() { if command -v shasum >/dev/null; then shasum -a 256 "$1" | cut -d' ' -f1; else sha256sum "$1" | cut -d' ' -f1; fi; }

fetch() { # fetch <platform> <sha256>
    local name="mihomo-$1-$VERSION.gz"
    echo "== $name"
    curl -fL --retry 3 -o "$tmp/$name" "https://github.com/MetaCubeX/mihomo/releases/download/$VERSION/$name"
    local got; got="$(sha256 "$tmp/$name")"
    if [[ "$got" != "$2" ]]; then
        echo "SHA-256 не совпал для $name: $got (ждали $2)" >&2
        exit 1
    fi
    gunzip -c "$tmp/$name" > "$tmp/mihomo-$1"
    chmod +x "$tmp/mihomo-$1"
}

if [[ "$(uname -s)" == "Darwin" ]]; then
    fetch darwin-arm64 "$SHA_ARM64"
    fetch darwin-amd64 "$SHA_AMD64"
    lipo -create -output "$tmp/mihomo" "$tmp/mihomo-darwin-arm64" "$tmp/mihomo-darwin-amd64"
    # Файлы из интернета macOS помечает карантином — снять, иначе служба может не запустить ядро.
    xattr -c "$tmp/mihomo" 2>/dev/null || true
else
    # Linux: только чтобы гонять службу для разработки и проверять конфиги (mihomo -t).
    fetch linux-amd64 "$SHA_LINUX_AMD64"
    mv "$tmp/mihomo-linux-amd64" "$tmp/mihomo"
fi

mkdir -p "$(dirname "$out")"
mv "$tmp/mihomo" "$out"
echo "готово: $out ($("$out" -v | head -1))"
