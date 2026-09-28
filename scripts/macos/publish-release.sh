#!/bin/bash
# Выложить собранный пакет в Releases: klick-<версия>.pkg и klick-macos.pkg — для постоянной ссылки
# https://github.com/<владелец>/<репозиторий>/releases/latest/download/klick-macos.pkg
# Версия — из Cargo.toml. Если тега v<версия> ещё нет, gh ставит его на этот коммит.
# Запускают workflow после сборки и проверок (нужны GH_TOKEN и GITHUB_REPOSITORY):
#   scripts/macos/publish-release.sh
set -euo pipefail
cd "$(dirname "$0")/../.."

ver="$(sed -n 's/^version = "\(.*\)"/\1/p' Cargo.toml | head -1)"
tag="v$ver"
repo="${GITHUB_REPOSITORY:?нужен GITHUB_REPOSITORY (владелец/репозиторий)}"
commit="${GITHUB_SHA:-$(git rev-parse HEAD)}"
pkg="dist/klick-$ver.pkg"
[[ -f "$pkg" ]] || { echo "нет $pkg — сначала scripts/macos/build.sh" >&2; exit 1; }
if gh release view "$tag" --repo "$repo" >/dev/null 2>&1; then
    echo "выпуск $tag уже есть — поднимите версию в Cargo.toml" >&2
    exit 1
fi

cp "$pkg" dist/klick-macos.pkg
notes="$(mktemp)"
trap 'rm -f "$notes"' EXIT
cat > "$notes" <<NOTES
kl!ck $ver для macOS 12+ (Apple Silicon и Intel).

Установка из Терминала (пакет не подписан сертификатом Apple, поэтому так проще, чем двойным щелчком):

\`\`\`sh
curl -fL -o /tmp/klick.pkg https://github.com/$repo/releases/download/$tag/klick-macos.pkg
sudo installer -pkg /tmp/klick.pkg -target /
open -a 'kl!ck'
\`\`\`

Удаление: \`sudo '/Applications/kl!ck.app/Contents/Resources/uninstall.sh'\`
NOTES

gh release create "$tag" "$pkg" dist/klick-macos.pkg --repo "$repo" --target "$commit" \
    --title "kl!ck $ver для macOS" --notes-file "$notes"
echo "выпуск: https://github.com/$repo/releases/tag/$tag"
