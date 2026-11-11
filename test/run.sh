#!/usr/bin/env bash
# Tests with saml2aws/aws stubs: they never touch Okta, AWS or your ~/.aws.
# Portable on purpose (Linux and macOS, bash 3.2+); the zsh tests run if zsh is installed.
set -uo pipefail

repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
t=$(mktemp -d)
trap 'rm -rf "$t"' EXIT
mkdir -p "$t/bin"

cat >"$t/bin/saml2aws" <<'EOF'
#!/usr/bin/env bash
cmd=$1; shift; tile=; prof=; dur=43200; role=; skip=
while (($#)); do
  case $1 in
    -a) tile=$2; shift ;; --profile) prof=$2; shift ;; --role) role=$2; shift ;;
    --session-duration) dur=$2; shift ;; --skip-prompt) skip=1 ;;
  esac
  shift
done
if [[ $cmd == list-roles ]]; then
  if [[ $tile == tile-a ]]; then
    printf '\nAccount: acme-prod-web (111111111111)\narn:aws:iam::111111111111:role/admin\n'
    printf '\nAccount: acme-dev-web (222222222222)\narn:aws:iam::222222222222:role/admin\narn:aws:iam::222222222222:role/ops/ReadOnly\n'
  else
    printf '\nAccount: 333333333333\narn:aws:iam::333333333333:role/admin\n'
    printf '\nAccount: acme-prod-web (111111111111)\narn:aws:iam::111111111111:role/admin\n'
  fi
  exit 0
fi
if [[ $tile == tile-b && -n $skip && ! -f $KEYRING ]]; then
  echo "error validating login details: Empty password" >&2; exit 1
fi
[[ $tile == tile-b ]] && touch "$KEYRING"
if [[ $role == *ReadOnly && $dur -gt 28800 ]]; then
  echo "ValidationError: The requested DurationSeconds exceeds the MaxSessionDuration" >&2; exit 1
fi
echo "$tile $prof dur=$dur skip=$skip" >>"$LOGINS"
exp=$(($(date +%s) + dur))
ts=$(date -u -d "@$exp" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -r "$exp" +%Y-%m-%dT%H:%M:%SZ)
printf '[%s]\nx_security_token_expires = %s\n' "$prof" "$ts" >>"$AWS_SHARED_CREDENTIALS_FILE"
EOF
cat >"$t/bin/aws" <<'EOF'
#!/usr/bin/env bash
case "$1 $2" in
  "iam get-role") echo 28800 ;;
  "configure get") echo us-west-2 ;;
  "eks update-kubeconfig") echo "$*" >>"$EKS_LOG" ;;
esac
EOF
chmod +x "$t/bin/"*
# `#!/usr/bin/env bash` in the stubs and libexec/ gets the bash running the tests, e.g. /bin/bash 3.2 on macOS.
ln -s "$BASH" "$t/bin/bash"

printf '[default]\nurl = x\n\n[tile-a]\nurl = a\n\n[tile-b]\nurl = b\n' >"$t/saml2aws"
printf '[default]\nregion = us-east-1\n' >"$t/config"
: >"$t/credentials"
unset AWS_PROFILE AWS_REGION AWS_DEFAULT_REGION AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
export PATH="$t/bin:$PATH" SAML2AWS_CONFIGFILE=$t/saml2aws AWS_CONFIG_FILE=$t/config \
  AWS_SHARED_CREDENTIALS_FILE=$t/credentials AWSP_DIR=$t/awsp LOGINS=$t/logins KEYRING=$t/keyring \
  EKS_LOG=$t/eks

fails=0
check() { # description, command
  if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fails=$((fails + 1)); fi
}
# sed -i differs between GNU and BSD sed.
subst() { sed "$1" "$2" >"$2.new" && mv "$2.new" "$2"; }

# shellcheck source=../awsp.sh
source "$repo/awsp.sh"

check "no inventory: asks for awsp sync" '[[ $(awsp x 2>&1) == *"awsp sync"* ]]'

awsp sync >/dev/null 2>&1
db=$t/awsp/profiles.tsv
check "sync builds 4 profiles (dedup across tiles)" '[[ $(wc -l <"$db") -eq 4 ]]'
check "name from account alias" 'grep -q "^acme-dev-web-readonly	tile-a	arn:aws:iam::222222222222:role/ops/ReadOnly" "$db"'
check "account without alias uses its id" 'grep -q "^333333333333-admin	tile-b" "$db"'
check "no \\r in the inventory" '! grep -q $'"'"'\r'"'"' "$db"'
check "managed block in ~/.aws/config" 'grep -q "^\[profile acme-prod-web-admin\]" "$t/config"'
awsp sync >/dev/null 2>&1
check "sync is idempotent" '[[ $(grep -c "awsp managed" "$t/config") -eq 2 ]]'
subst 's/^# >>> awsp managed.*/# >>> awsp managed (old marker) >>>/' "$t/config"
awsp sync >/dev/null 2>&1
check "replaces blocks with older markers" '[[ $(grep -c "awsp managed" "$t/config") -eq 2 ]]'
subst '/	tile-a	/s/	arn:/	arn:x/' "$db"
awsp sync tile-b >/dev/null 2>&1
check "sync <tile> keeps the other tiles' rows" '[[ $(grep -c "	arn:xaws:" "$db") -eq 3 ]]'
awsp sync >/dev/null 2>&1

# Every row has text starting exactly where each header column starts.
list_aligned() {
  awsp list | sed 's/[●○]/o/g' | awk '
    NR == 1 {n = split("SESSION ACCOUNT ID TILE", h, " "); for (i = 1; i <= n; i++) c[i] = index($0, h[i]); next}
    {for (i = 1; i <= n; i++) if (substr($0, c[i] - 1, 2) !~ /^ [^ ]/) bad = 1}
    END {exit bad}'
}
check "list with no sessions yet" '[[ $(awsp list | wc -l) -eq 5 && $(awsp -l | wc -l) -eq 5 ]] && awsp list | head -1 | grep -q "^PROFILE"'
printf '[a]\nx_security_token_expires = 2026-11-11T12:35:35-03:00\n[b]\nx_security_token_expires = 2026-11-11T15:35:35Z\n[c]\nx_security_token_expires = 2024-02-29T23:59:59.5+05:30\n' >"$t/fixed"
check "expiry: RFC 3339 offsets, Z and fractions, without GNU date" \
  '[[ $(AWS_SHARED_CREDENTIALS_FILE=$t/fixed _awsp_expiries | tr "\t\n" ":,") == a:1794411335,b:1794411335,c:1709231399, ]]'
check "awsp help lists the subcommands" '[[ $(awsp help) == *"awsp setup"*"awsp sync"*"awsp eks"* ]]'

COMP_WORDS=(awsp s) COMP_CWORD=1; _awsp_complete
check "completes subcommands" '[[ ${COMPREPLY[*]} == "setup sync" ]]'
COMP_WORDS=(awsp sync "") COMP_CWORD=2; _awsp_complete
check "completes tiles after sync" '[[ ${COMPREPLY[*]} == "tile-a tile-b" ]]'

check "awsp eks without a profile fails" '! awsp eks c1 2>/dev/null && [[ ! -e $EKS_LOG ]]'
awsp acme-prod-web-admin >/dev/null 2>&1
check "login and AWS_PROFILE" '[[ $AWS_PROFILE == acme-prod-web-admin ]] && [[ $(wc -l <"$LOGINS") -eq 1 ]]'
awsp acme-prod-web-admin >/dev/null 2>&1
check "active session: no new login" '[[ $(wc -l <"$LOGINS") -eq 1 ]]'
check "list columns line up with the header" 'awsp -l | grep -q "^acme-prod-web-admin  *● " && list_aligned'

export AWS_ACCESS_KEY_ID=zzz
awsp arn:aws:iam::222222222222:role/ops/ReadOnly >/dev/null 2>&1
check "by ARN, clears env credentials" '[[ $AWS_PROFILE == acme-dev-web-readonly && -z ${AWS_ACCESS_KEY_ID:-} ]]'
check "duration fallback, maximum remembered" 'grep -q "^acme-dev-web-readonly	28800$" "$t/awsp/durations.tsv"'

awsp 333333333333-admin >/dev/null 2>&1
check "no saved password: retries with prompt" 'grep -q "^tile-b 333333333333-admin dur=43200 skip=$" "$LOGINS"'

awsp eks c1 >/dev/null 2>&1
check "awsp eks: context bound to the profile" \
  'grep -q -- "--name c1 --region us-west-2 --profile 333333333333-admin --alias 333333333333-admin/c1" "$EKS_LOG"'

awsp off
check "awsp off" '[[ -z ${AWS_PROFILE:-} ]]'

cfg=$t/setup.saml2aws
printf '[team-a]\nurl = x\nusername = me@example.com\nmfa = PUSH\naws_session_duration = 14400\n' >"$cfg"
# Bad URL, valid URL, existing name, invalid name, valid name, 4 defaults, no more tiles, no sync.
printf '%s\n' not-a-url 'https://example.okta.com/home/amazon_aws/0oaABC/272?fromHome=true' \
  team-a 'team b' team-b '' '' '' '' n n |
  SAML2AWS_CONFIGFILE=$cfg awsp setup >/dev/null 2>&1
check "setup appends a tile" 'grep -qx "\[team-b\]" "$cfg" && [[ $(grep -c "^\[" "$cfg") -eq 2 ]]'
check "setup strips the URL query" 'grep -q "^url  *= https://example.okta.com/home/amazon_aws/0oaABC/272$" "$cfg"'
check "setup defaults from existing tiles" 'grep -q "^username  *= me@example.com$" "$cfg" && grep -q "^mfa  *= PUSH$" "$cfg" && grep -q "^aws_session_duration  *= 14400$" "$cfg"'
check "setup enables saml_cache per tile" 'grep -q "^saml_cache_file  *= .*/saml_cache_team-b.xml$" "$cfg"'
check "setup backs up the config" '[[ -f $cfg.bak.awsp ]] && ! grep -q team-b "$cfg.bak.awsp"'

printf '%s\n' 'https://example.okta.com/home/amazon_aws/0oaDEF/272' team-c u@example.com '' 12 eu-west-1 n y |
  SAML2AWS_CONFIGFILE=$cfg AWSP_DIR=$t/awsp2 awsp setup >/dev/null 2>&1
check "setup runs awsp sync for the new tile" '[[ $(cut -f2 "$t/awsp2/profiles.tsv" | sort -u) == team-c ]]'

if command -v zsh >/dev/null 2>&1; then
  : >"$AWS_SHARED_CREDENTIALS_FILE"
  : >"$LOGINS"
  # A file, not stdin: script(1) inside the login would eat the rest of the commands.
  cat >"$t/test.zsh" <<EOF
source "$repo/awsp.sh"
print "list=\$(awsp list | wc -l | tr -d ' ')"
# stdout too: with no TTY on stdin, BSD script(1) echoes a ^D there, with no newline.
awsp acme-dev-web-readonly >/dev/null 2>&1
print "profile=\$AWS_PROFILE"
awsp off
print "off=\${AWS_PROFILE:-unset}"
print "sync=\$(awsp sync tile-b 2>&1 | grep -c '==> \[')"
print "cands=\$(_awsp_candidates 1 '' | tr '\n' ' ')"
print "tiles=\$(_awsp_candidates 2 sync | tr '\n' ' ')"
autoload -Uz compinit && compinit -u -D
source "$repo/awsp.sh"
print "compdef=\${_comps[awsp]}"
EOF
  zsh -f "$t/test.zsh" >"$t/zsh.out" 2>"$t/zsh.err" </dev/null
  fails_before_zsh=$fails
  check "zsh: awsp list" 'grep -qx "list=5" "$t/zsh.out"'
  check "zsh: login with a remembered duration, exports AWS_PROFILE" \
    'grep -qx "profile=acme-dev-web-readonly" "$t/zsh.out" && grep -qx "tile-a acme-dev-web-readonly dur=28800 skip=1" "$LOGINS"'
  check "zsh: awsp off" 'grep -qx "off=unset" "$t/zsh.out"'
  check "zsh: awsp sync <tile> passes the tile on" 'grep -qx "sync=1" "$t/zsh.out"'
  check "zsh: completion candidates" \
    'grep -q "^cands=setup sync eks list off help .*acme-prod-web-admin" "$t/zsh.out" && grep -qx "tiles=tile-a tile-b " "$t/zsh.out"'
  check "zsh: completion registered with compdef" 'grep -qx "compdef=_awsp_zsh_complete" "$t/zsh.out"'
  check "zsh: nothing on stderr" '[[ ! -s $t/zsh.err ]]'
  if ((fails > fails_before_zsh)); then
    for f in zsh.out zsh.err logins; do echo "--- $f"; cat -v "$t/$f"; done
  fi
else
  echo "skip zsh tests (zsh not installed)"
fi

# install.sh in scratch HOMEs, with a fake uname to cover both systems from either.
for os in Linux Darwin; do
  mkdir -p "$t/os/$os"
  printf '#!/bin/sh\necho %s\n' "$os" >"$t/os/$os/uname"
  chmod +x "$t/os/$os/uname"
done
# install_as HOME OS SHELL [VAR=value…]
install_as() {
  local home=$1 os=$2 shell=$3
  shift 3
  mkdir -p "$home"
  env HOME="$home" SHELL="$shell" PATH="$t/os/$os:$PATH" AWSP_DIR= BINDIR= AWSP_RC= ZDOTDIR= "$@" \
    "$repo/install.sh" >/dev/null 2>&1
}

h=$t/home1
mkdir -p "$h/.local/bin"
ln -s /nonexistent/awsp-sync "$h/.local/bin/awsp-sync"
install_as "$h" Darwin /bin/zsh
install_as "$h" Darwin /bin/zsh
check "install: links awsp.sh and removes old links" '[[ -L $h/.config/awsp/awsp.sh && ! -L $h/.local/bin/awsp-sync ]]'
check "install: zsh gets one line in ~/.zshrc" '[[ $(grep -c awsp.sh "$h/.zshrc") -eq 1 ]]'

install_as "$t/home2" Linux /bin/zsh ZDOTDIR="$t/home2/zdot"
check "install: zsh honors ZDOTDIR" 'grep -q awsp.sh "$t/home2/zdot/.zshrc" && [[ ! -e $t/home2/.zshrc ]]'

install_as "$t/home3" Linux /bin/bash
check "install: bash on Linux gets ~/.bashrc" 'grep -q awsp.sh "$t/home3/.bashrc"'

install_as "$t/home4" Darwin /bin/bash
check "install: bash on macOS gets ~/.bash_profile and ~/.bashrc" \
  'grep -q awsp.sh "$t/home4/.bash_profile" && grep -q awsp.sh "$t/home4/.bashrc"'

h=$t/home5
mkdir -p "$h"
echo 'export FROM_PROFILE=1' >"$h/.profile"
install_as "$h" Darwin /bin/bash
check "install: bash on macOS keeps an existing ~/.profile in use" \
  '[[ ! -e $h/.bash_profile ]] && grep -q "BASH_VERSION.*awsp.sh" "$h/.profile" && grep -q awsp.sh "$h/.bashrc"'
check "install: the ~/.profile line is harmless in sh" '[[ -z $(HOME=$h sh -c ". ~/.profile" 2>&1) ]]'
check "install: bash login shells load awsp from ~/.profile" \
  '[[ $(HOME=$h "$BASH" -lc "type -t awsp; echo \$FROM_PROFILE" 2>/dev/null) == function*1 ]]'

echo
((fails == 0)) && echo "all ok" || { echo "$fails failed"; exit 1; }
