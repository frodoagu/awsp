#!/usr/bin/env bash
# Instala awsp con symlinks al repo (un `git pull` alcanza para actualizar).
set -euo pipefail

repo=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
cfg=${AWSP_DIR:-$HOME/.config/awsp}
bindir=${BINDIR:-$HOME/.local/bin}

mkdir -p "$cfg" "$bindir"
ln -sfn "$repo/awsp.sh" "$cfg/awsp.sh"
ln -sfn "$repo/bin/awsp-sync" "$bindir/awsp-sync"

for dep in saml2aws aws fzf script; do
  command -v "$dep" >/dev/null || echo "falta '$dep' en el PATH" >&2
done

line='[ -f ~/.config/awsp/awsp.sh ] && . ~/.config/awsp/awsp.sh'
if ! grep -qF "$line" "$HOME/.bashrc" 2>/dev/null; then
  printf '\n# awsp: selector de perfiles AWS sobre saml2aws\n%s\n' "$line" >>"$HOME/.bashrc"
  echo "agregado a ~/.bashrc: $line"
fi
echo "listo: abrí una terminal nueva y corré awsp-sync"
