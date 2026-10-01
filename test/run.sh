#!/usr/bin/env bash
# Tests con stubs de saml2aws/aws: no tocan Okta, AWS ni tu ~/.aws.
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
printf '[%s]\nx_security_token_expires = %s\n' "$prof" "$(date -d "+$dur sec" --iso-8601=seconds)" \
  >>"$AWS_SHARED_CREDENTIALS_FILE"
EOF
printf '#!/bin/sh\necho 28800\n' >"$t/bin/aws"
chmod +x "$t/bin/"*

printf '[default]\nurl = x\n\n[tile-a]\nurl = a\n\n[tile-b]\nurl = b\n' >"$t/saml2aws"
printf '[default]\nregion = us-east-1\n' >"$t/config"
: >"$t/credentials"
export PATH="$t/bin:$PATH" SAML2AWS_CONFIGFILE=$t/saml2aws AWS_CONFIG_FILE=$t/config \
  AWS_SHARED_CREDENTIALS_FILE=$t/credentials AWSP_DIR=$t/awsp LOGINS=$t/logins KEYRING=$t/keyring

fails=0
check() { # descripción, comando
  if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fails=$((fails + 1)); fi
}

"$repo/bin/awsp-sync" >/dev/null 2>&1
db=$t/awsp/profiles.tsv
check "sync genera 4 perfiles (dedup entre tiles)" '[[ $(wc -l <"$db") -eq 4 ]]'
check "nombre desde alias de cuenta" 'grep -q "^acme-dev-web-readonly	tile-a	arn:aws:iam::222222222222:role/ops/ReadOnly" "$db"'
check "cuenta sin alias usa el id" 'grep -q "^333333333333-admin	tile-b" "$db"'
check "sin \\r en el inventario" '! grep -q $'"'"'\r'"'"' "$db"'
check "bloque administrado en ~/.aws/config" 'grep -q "^\[profile acme-prod-web-admin\]" "$t/config"'
"$repo/bin/awsp-sync" >/dev/null 2>&1
check "sync idempotente" '[[ $(grep -c "awsp managed" "$t/config") -eq 2 ]]'

# shellcheck source=../awsp.sh
source "$repo/awsp.sh"
awsp acme-prod-web-admin >/dev/null 2>&1
check "login y AWS_PROFILE" '[[ $AWS_PROFILE == acme-prod-web-admin ]] && [[ $(wc -l <"$LOGINS") -eq 1 ]]'
awsp acme-prod-web-admin >/dev/null 2>&1
check "sesión vigente: no vuelve a loguear" '[[ $(wc -l <"$LOGINS") -eq 1 ]]'

export AWS_ACCESS_KEY_ID=zzz
awsp arn:aws:iam::222222222222:role/ops/ReadOnly >/dev/null 2>&1
check "por ARN y limpia variables de entorno" '[[ $AWS_PROFILE == acme-dev-web-readonly && -z ${AWS_ACCESS_KEY_ID:-} ]]'
check "fallback de duración y máximo recordado" 'grep -q "^acme-dev-web-readonly	28800$" "$t/awsp/durations.tsv"'

awsp 333333333333-admin >/dev/null 2>&1
check "sin password guardada: reintenta con prompt" 'grep -q "^tile-b 333333333333-admin dur=43200 skip=$" "$LOGINS"'

awsp off
check "awsp off" '[[ -z ${AWS_PROFILE:-} ]]'

echo
((fails == 0)) && echo "todo ok" || { echo "$fails fallas"; exit 1; }
