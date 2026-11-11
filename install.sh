#!/usr/bin/env bash
# Install awsp as a symlink into this repo (a `git pull` is enough to update).
set -euo pipefail

repo=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
cfg=${AWSP_DIR:-$HOME/.config/awsp}
bindir=${BINDIR:-$HOME/.local/bin}

mkdir -p "$cfg"
ln -sfn "$repo/awsp.sh" "$cfg/awsp.sh"

# Older versions linked awsp-sync and awsp-setup into ~/.local/bin; they are `awsp sync` and `awsp setup` now.
for old in awsp-sync awsp-setup; do
  if [[ -L $bindir/$old ]]; then
    rm -f "$bindir/$old"
    echo "removed old $bindir/$old (now: awsp ${old#awsp-})"
  fi
done

for dep in saml2aws aws fzf script; do
  command -v "$dep" >/dev/null || echo "missing '$dep' in PATH" >&2
done

# The startup file of your login shell; override with AWSP_RC.
# Terminal on macOS opens login shells, which read ~/.bash_profile rather than ~/.bashrc.
if [[ -n ${AWSP_RC:-} ]]; then
  rc=$AWSP_RC
elif [[ ${SHELL:-} == */zsh ]]; then
  rc=$HOME/.zshrc
elif [[ $(uname -s) == Darwin ]]; then
  rc=$HOME/.bash_profile
else
  rc=$HOME/.bashrc
fi
line='[ -f ~/.config/awsp/awsp.sh ] && . ~/.config/awsp/awsp.sh'
if ! grep -qF "$line" "$rc" 2>/dev/null; then
  printf '\n# awsp: AWS profile picker on top of saml2aws\n%s\n' "$line" >>"$rc"
  echo "added to $rc: $line"
fi
echo "done: open a new terminal and run awsp setup (or awsp sync if ~/.saml2aws already has your tiles)"
