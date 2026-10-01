# awsp: selector de perfiles AWS sobre saml2aws. Se carga desde ~/.bashrc.
#
#   awsp                 menú fzf con todos los perfiles (● = sesión vigente)
#   awsp <texto>         perfil exacto, o fzf prefiltrado (elige solo si hay uno)
#   awsp arn:aws:iam::…  por ARN de rol
#   awsp off             limpia AWS_PROFILE y credenciales en variables de entorno
#   awsp -l              lista perfiles y estado de sesión
#   awsp-eks [cluster…]  agrega/actualiza contextos de kubectl atados al perfil actual
#
# El inventario (profiles.tsv) lo genera awsp-sync.

AWSP_DIR=${AWSP_DIR:-$HOME/.config/awsp}
AWSP_DB=$AWSP_DIR/profiles.tsv
# "perfil<TAB>segundos" para roles cuyo máximo es menor al aws_session_duration del tile.
AWSP_DURATIONS=$AWSP_DIR/durations.tsv

# "perfil<TAB>epoch de expiración" según x_security_token_expires de saml2aws.
_awsp_expiries() {
  local f=${AWS_SHARED_CREDENTIALS_FILE:-$HOME/.aws/credentials} p exp
  [[ -r $f ]] || return 0
  awk -F' *= *' '/^\[/ {p = substr($0, 2, length($0) - 2); next}
    $1 == "x_security_token_expires" {print p "\t" $2}' "$f" |
    while IFS=$'\t' read -r p exp; do
      printf '%s\t%s\n' "$p" "$(date -d "$exp" +%s 2>/dev/null || echo 0)"
    done
}

_awsp_list() {
  awk -F'\t' -v now="$(date +%s)" '
    NR == FNR {ttl[$1] = $2; next}
    {
      left = ttl[$1] - now
      st = left > 300 ? sprintf("● %dh%02dm", int(left / 3600), int(left % 3600 / 60)) : "○"
      printf "%-50s %-9s %-40s %-13s %s\n", $1, st, $5, $4, $2
    }' <(_awsp_expiries) "$AWSP_DB"
}

_awsp_valid() {
  local exp
  exp=$(_awsp_expiries | awk -F'\t' -v p="$1" '$1 == p {print $2}')
  [[ -n $exp ]] && ((exp > $(date +%s) + 300))
}

# saml2aws login dentro de `script` para tener TTY (prompts) y a la vez leer los errores.
_awsp_run_login() {
  local log=$1; shift
  script -qec "$(printf '%q ' saml2aws login "$@")" "$log"
}

_awsp_set_duration() {
  local tmp
  tmp=$(mktemp)
  awk -F'\t' -v p="$1" '$1 != p' "$AWSP_DURATIONS" 2>/dev/null >"$tmp"
  printf '%s\t%s\n' "$1" "$2" >>"$tmp"
  mv "$tmp" "$AWSP_DURATIONS"
}

_awsp_login() {
  local profile=$1 tile=$2 arn=$3 log rc dur max
  local args=(-a "$tile" --role "$arn" --profile "$profile" --force --cache-saml)
  local prompt=--skip-prompt
  dur=$(awk -F'\t' -v p="$profile" '$1 == p {print $2}' "$AWSP_DURATIONS" 2>/dev/null)
  log=$(mktemp)

  _awsp_run_login "$log" "${args[@]}" $prompt ${dur:+--session-duration "$dur"}; rc=$?
  if ((rc)) && grep -qi 'empty password\|authenticat' "$log"; then
    echo "awsp: no hay password guardada para el tile $tile; escribila (queda en el keyring)" >&2
    prompt=
    _awsp_run_login "$log" "${args[@]}" ${dur:+--session-duration "$dur"}; rc=$?
  fi
  if ((rc)) && grep -q 'DurationSeconds' "$log"; then
    echo "awsp: el rol no acepta esa duración; entro con 1h y averiguo su máximo" >&2
    _awsp_run_login "$log" "${args[@]}" $prompt --session-duration 3600; rc=$?
    if ((rc == 0)); then
      max=$(aws iam get-role --profile "$profile" --role-name "${arn##*/}" \
        --query Role.MaxSessionDuration --output text 2>/dev/null)
      [[ $max =~ ^[0-9]+$ ]] || max=3600
      _awsp_set_duration "$profile" "$max"
      echo "awsp: $profile admite hasta $((max / 3600))h; la próxima vez uso eso" >&2
    fi
  fi
  rm -f "$log"
  return "$rc"
}

awsp() {
  if [[ ! -s $AWSP_DB ]]; then
    echo "awsp: no hay inventario; corré awsp-sync primero" >&2
    return 1
  fi

  local profile=
  case ${1:-} in
    off | -)
      unset AWS_PROFILE AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN \
        AWS_SECURITY_TOKEN AWS_CREDENTIAL_EXPIRATION
      return 0 ;;
    -l | --list) _awsp_list; return 0 ;;
    -h | --help) sed -n '3,11s/^# \{0,1\}//p' "${BASH_SOURCE[0]}"; return 0 ;;
    arn:*) profile=$(awk -F'\t' -v a="$1" '$3 == a {print $1; exit}' "$AWSP_DB") ;;
    ?*) profile=$(awk -F'\t' -v p="$1" '$1 == p {print $1; exit}' "$AWSP_DB") ;;
  esac
  if [[ -z $profile ]]; then
    [[ ${1:-} == arn:* ]] && { echo "awsp: no conozco $1 (¿falta awsp-sync?)" >&2; return 1; }
    profile=$(_awsp_list | fzf --height 50% --reverse --no-sort --query "$*" --select-1 --exit-0 \
      --header 'perfil  sesión  cuenta  id  tile' | awk '{print $1}')
    [[ -n $profile ]] || return 1
  fi

  local tile arn acct label
  IFS=$'\t' read -r _ tile arn acct label < <(awk -F'\t' -v p="$profile" '$1 == p' "$AWSP_DB")

  if ! _awsp_valid "$profile"; then
    echo "awsp: login en $profile ($tile)…" >&2
    _awsp_login "$profile" "$tile" "$arn" || { echo "awsp: falló el login" >&2; return 1; }
  fi

  unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_SECURITY_TOKEN AWS_CREDENTIAL_EXPIRATION
  export AWS_PROFILE=$profile
  echo "AWS_PROFILE=$profile  ($label / $acct, rol ${arn##*/})" >&2
}

awsp-eks() {
  if [[ -z ${AWS_PROFILE:-} ]]; then
    echo "awsp-eks: primero elegí un perfil con awsp" >&2
    return 1
  fi
  local region=${AWS_REGION:-$(aws configure get region --profile "$AWS_PROFILE")} c
  local clusters=("$@")
  if ((${#clusters[@]} == 0)); then
    mapfile -t clusters < <(aws eks list-clusters --region "${region:-us-east-1}" --query 'clusters[]' --output text |
      tr '\t' '\n' | fzf --multi --height 40% --reverse --select-1 --exit-0 --prompt 'cluster> ')
  fi
  for c in "${clusters[@]}"; do
    # --profile hace que el kubeconfig fije AWS_PROFILE en el exec de `aws eks get-token`.
    aws eks update-kubeconfig --name "$c" --region "${region:-us-east-1}" \
      --profile "$AWS_PROFILE" --alias "$AWS_PROFILE/$c"
  done
}

_awsp_complete() {
  ((COMP_CWORD == 1)) || return
  [[ -r $AWSP_DB ]] || return
  mapfile -t COMPREPLY < <(compgen -W "off -l $(cut -f1 "$AWSP_DB")" -- "${COMP_WORDS[1]}")
}
complete -F _awsp_complete awsp
