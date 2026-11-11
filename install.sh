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

# Startup files that load awsp; AWSP_RC overrides them.
# - zsh: $ZDOTDIR/.zshrc (ZDOTDIR defaults to ~).
# - bash on Linux: ~/.bashrc.
# - bash on macOS: Terminal opens login shells, which read only the first of ~/.bash_profile,
#   ~/.bash_login and ~/.profile that exists. Use that one, so that a new ~/.bash_profile
#   doesn't hide an existing ~/.profile, plus ~/.bashrc for non-login shells.
if [[ -n ${AWSP_RC:-} ]]; then
  rcs=("$AWSP_RC")
elif [[ ${SHELL:-} == */zsh ]]; then
  rcs=("${ZDOTDIR:-$HOME}/.zshrc")
elif [[ $(uname -s) == Darwin ]]; then
  login=$HOME/.bash_profile
  for f in "$HOME/.bash_profile" "$HOME/.bash_login" "$HOME/.profile"; do
    if [[ -f $f ]]; then
      login=$f
      break
    fi
  done
  rcs=("$login" "$HOME/.bashrc")
else
  rcs=("$HOME/.bashrc")
fi
line='[ -f ~/.config/awsp/awsp.sh ] && . ~/.config/awsp/awsp.sh'
for rc in "${rcs[@]}"; do
  # Also matches the guarded variant below.
  if grep -qF '. ~/.config/awsp/awsp.sh' "$rc" 2>/dev/null; then
    continue
  fi
  add=$line
  if [[ ${rc##*/} == .profile ]]; then
    # sh reads ~/.profile too and can't parse awsp.sh: load it only from bash, outside POSIX mode.
    add='[ -n "${BASH_VERSION:-}" ] && ! shopt -oq posix && '$line
  fi
  mkdir -p "$(dirname "$rc")"
  printf '\n# awsp: AWS profile picker on top of saml2aws\n%s\n' "$add" >>"$rc"
  echo "added to $rc: $add"
done
echo "done: open a new terminal and run awsp setup (or awsp sync if ~/.saml2aws already has your tiles)"
