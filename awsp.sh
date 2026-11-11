# awsp: AWS profile picker on top of saml2aws. Sourced from ~/.bashrc or ~/.zshrc (bash 3.2+ or zsh).
#
#   awsp                 fzf menu with every profile (● = active session)
#   awsp <text>          exact profile, or pre-filtered fzf (auto-picks a single match)
#   awsp arn:aws:iam::…  by role ARN
#   awsp setup           add Okta AWS tiles to ~/.saml2aws interactively, then sync them
#   awsp sync [tile…]    rebuild the profile inventory from the Okta tiles in ~/.saml2aws
#   awsp eks [cluster…]  add/update kubectl contexts bound to the current profile
#   awsp list            list profiles and their session status (also -l)
#   awsp off             clear AWS_PROFILE and any credentials in environment variables
#   awsp help            show this help (also -h)

# This file with symlinks resolved (~/.config/awsp/awsp.sh points into the repo);
# the helper scripts live in the repo's libexec/. No `readlink -f`: older macOS lacks it.
if [[ -n ${ZSH_VERSION:-} ]]; then
  eval '_AWSP_SRC=${(%):-%x}'
else
  _AWSP_SRC=${BASH_SOURCE[0]}
fi
[[ $_AWSP_SRC == /* ]] || _AWSP_SRC=$PWD/$_AWSP_SRC
while [[ -L $_AWSP_SRC ]]; do
  _awsp_link=$(readlink "$_AWSP_SRC")
  [[ $_awsp_link == /* ]] || _awsp_link=${_AWSP_SRC%/*}/$_awsp_link
  _AWSP_SRC=$_awsp_link
done
unset _awsp_link
_AWSP_ROOT=${_AWSP_SRC%/*}
AWSP_DIR=${AWSP_DIR:-$HOME/.config/awsp}
AWSP_DB=$AWSP_DIR/profiles.tsv
# "profile<TAB>seconds" for roles whose maximum is below the tile's aws_session_duration.
AWSP_DURATIONS=$AWSP_DIR/durations.tsv

# "profile<TAB>expiry epoch" from saml2aws' x_security_token_expires, an RFC 3339
# timestamp such as 2026-11-11T12:35:35-03:00 or 2026-11-11T15:35:35Z.
# Converted in awk because `date -d` is GNU-only.
_awsp_expiries() {
  local f=${AWS_SHARED_CREDENTIALS_FILE:-$HOME/.aws/credentials}
  [[ -r $f ]] || return 0
  awk -F' *= *' '
    function epoch(s,   y, m, d, z, off, era, yoe, doy, days) {
      if (s !~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9][Tt ][0-9][0-9]:[0-9][0-9]:[0-9][0-9]/) return 0
      y = substr(s, 1, 4) + 0; m = substr(s, 6, 2) + 0; d = substr(s, 9, 2) + 0
      off = 0
      if (match(s, /[+-][0-9][0-9]:?[0-9][0-9]$/)) {
        z = substr(s, RSTART + 1); gsub(/:/, "", z)
        off = (substr(z, 1, 2) * 3600 + substr(z, 3, 2) * 60) * (substr(s, RSTART, 1) == "-" ? -1 : 1)
      }
      # Days since 1970-01-01, using the days_from_civil algorithm by Howard Hinnant.
      if (m <= 2) y--
      era = int(y / 400); yoe = y - era * 400
      doy = int((153 * (m > 2 ? m - 3 : m + 9) + 2) / 5) + d - 1
      days = era * 146097 + yoe * 365 + int(yoe / 4) - int(yoe / 100) + doy - 719468
      return days * 86400 + substr(s, 12, 2) * 3600 + substr(s, 15, 2) * 60 + substr(s, 18, 2) - off
    }
    /^\[/ {p = substr($0, 2, length($0) - 2); next}
    $1 == "x_security_token_expires" {v = $2; sub(/[ \t\r]+$/, "", v); print p "\t" epoch(v)}' "$f"
}

# Header + one row per profile, aligned by `column` (which counts ●/○ as one column, unlike awk).
_awsp_list() {
  {
    printf 'PROFILE\tSESSION\tACCOUNT\tID\tTILE\n'
    # FILENAME, not NR == FNR: the expiries may be empty.
    awk -F'\t' -v OFS='\t' -v now="$(date +%s)" '
      FILENAME == ARGV[1] {ttl[$1] = $2; next}
      {
        left = ttl[$1] - now
        st = left > 300 ? sprintf("● %dh%02dm", int(left / 3600), int(left % 3600 / 60)) : "○"
        print $1, st, $5, $4, $2
      }' <(_awsp_expiries) "$AWSP_DB"
  } | column -t -s $'\t'
}

_awsp_valid() {
  local exp
  exp=$(_awsp_expiries | awk -F'\t' -v p="$1" '$1 == p {print $2}')
  [[ -n $exp ]] && ((exp > $(date +%s) + 300))
}

# saml2aws login with a TTY (so it can prompt), saving its output to $1 so we can read its errors.
_awsp_run_login() {
  local log=$1; shift
  "$_AWSP_ROOT/libexec/awsp-tty" "$log" saml2aws login "$@"
}

_awsp_set_duration() {
  local tmp
  tmp=$(mktemp)
  awk -F'\t' -v p="$1" '$1 != p' "$AWSP_DURATIONS" 2>/dev/null >"$tmp"
  printf '%s\t%s\n' "$1" "$2" >>"$tmp"
  mv "$tmp" "$AWSP_DURATIONS"
}

_awsp_login() {
  local profile=$1 tile=$2 arn=$3 log rc dur max skip=--skip-prompt
  local args=(-a "$tile" --role "$arn" --profile "$profile" --force --cache-saml)
  dur=$(awk -F'\t' -v p="$profile" '$1 == p {print $2}' "$AWSP_DURATIONS" 2>/dev/null)
  log=$(mktemp)

  # $skip and ${dur:+…} are unquoted on purpose: when empty they vanish, in bash and zsh alike.
  _awsp_run_login "$log" "${args[@]}" $skip ${dur:+--session-duration} ${dur:+"$dur"}; rc=$?
  if ((rc)) && grep -qiE 'empty password|authenticat' "$log"; then
    echo "awsp: no saved password for tile $tile; type it (it gets stored in the keyring)" >&2
    skip=
    _awsp_run_login "$log" "${args[@]}" ${dur:+--session-duration} ${dur:+"$dur"}; rc=$?
  fi
  if ((rc)) && grep -q 'DurationSeconds' "$log"; then
    echo "awsp: the role rejects that duration; logging in for 1h and looking up its maximum" >&2
    _awsp_run_login "$log" "${args[@]}" $skip --session-duration 3600; rc=$?
    if ((rc == 0)); then
      max=$(aws iam get-role --profile "$profile" --role-name "${arn##*/}" \
        --query Role.MaxSessionDuration --output text 2>/dev/null)
      [[ $max =~ ^[0-9]+$ ]] || max=3600
      _awsp_set_duration "$profile" "$max"
      echo "awsp: $profile allows up to $((max / 3600))h; will use that next time" >&2
    fi
  fi
  rm -f "$log"
  return "$rc"
}

# Usage lines from the header comment of this file.
_awsp_help() {
  awk 'NR > 2 && /^#/ {sub(/^# ?/, ""); print; next} NR > 2 {exit}' "$_AWSP_SRC"
}

awsp() {
  # Subcommands that don't need the inventory.
  case ${1:-} in
    setup | sync) "$_AWSP_ROOT/libexec/awsp-$1" "${@:2}"; return ;;
    eks) shift; _awsp_eks "$@"; return ;;
    off | -)
      unset AWS_PROFILE AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN \
        AWS_SECURITY_TOKEN AWS_CREDENTIAL_EXPIRATION
      return 0 ;;
    help | -h | --help) _awsp_help; return 0 ;;
  esac

  if [[ ! -s $AWSP_DB ]]; then
    echo "awsp: no inventory yet; run 'awsp setup' (or 'awsp sync' if ~/.saml2aws already has your tiles)" >&2
    return 1
  fi

  local profile=
  case ${1:-} in
    list | -l | --list) _awsp_list; return 0 ;;
    arn:*) profile=$(awk -F'\t' -v a="$1" '$3 == a {print $1; exit}' "$AWSP_DB") ;;
    ?*) profile=$(awk -F'\t' -v p="$1" '$1 == p {print $1; exit}' "$AWSP_DB") ;;
  esac
  if [[ -z $profile ]]; then
    [[ ${1:-} == arn:* ]] && { echo "awsp: unknown role $1 (need to run 'awsp sync'?)" >&2; return 1; }
    profile=$(_awsp_list | fzf --height 50% --reverse --no-sort --query "$*" --select-1 --exit-0 \
      --header-lines 1 | awk '{print $1}')
    [[ -n $profile ]] || return 1
  fi

  local name tile arn acct label
  IFS=$'\t' read -r name tile arn acct label < <(awk -F'\t' -v p="$profile" '$1 == p' "$AWSP_DB")

  if ! _awsp_valid "$profile"; then
    echo "awsp: logging in to $profile ($tile)…" >&2
    _awsp_login "$profile" "$tile" "$arn" || { echo "awsp: login failed" >&2; return 1; }
  fi

  unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_SECURITY_TOKEN AWS_CREDENTIAL_EXPIRATION
  export AWS_PROFILE=$profile
  echo "AWS_PROFILE=$profile  ($label / $acct, role ${arn##*/})" >&2
}

_awsp_eks() {
  if [[ -z ${AWS_PROFILE:-} ]]; then
    echo "awsp eks: pick a profile with awsp first" >&2
    return 1
  fi
  local region=${AWS_REGION:-$(aws configure get region --profile "$AWS_PROFILE")} c
  local clusters=("$@")
  if ((${#clusters[@]} == 0)); then
    while IFS= read -r c; do clusters+=("$c"); done < <(
      aws eks list-clusters --region "${region:-us-east-1}" --query 'clusters[]' --output text |
        tr '\t' '\n' | fzf --multi --height 40% --reverse --select-1 --exit-0 --prompt 'cluster> ')
  fi
  ((${#clusters[@]})) || return 1
  for c in "${clusters[@]}"; do
    # --profile makes the kubeconfig pin AWS_PROFILE in the `aws eks get-token` exec.
    aws eks update-kubeconfig --name "$c" --region "${region:-us-east-1}" \
      --profile "$AWS_PROFILE" --alias "$AWS_PROFILE/$c"
  done
}

# Completion candidates, one per line. $1: position of the word being completed
# (1 = first argument); $2: the first argument.
_awsp_candidates() {
  if (($1 == 1)); then
    printf '%s\n' setup sync eks list off help
    cut -f1 "$AWSP_DB" 2>/dev/null
  elif [[ $2 == sync ]]; then
    sed -n 's/^\[\(.*\)\][[:space:]]*$/\1/p' "${SAML2AWS_CONFIGFILE:-$HOME/.saml2aws}" 2>/dev/null |
      grep -vx default
  fi
  return 0
}

if [[ -n ${ZSH_VERSION:-} ]]; then
  _awsp_zsh_complete() {
    local -a cands
    local c
    while IFS= read -r c; do cands+=("$c"); done < <(_awsp_candidates "$((CURRENT - 1))" "${words[2]:-}")
    compadd -a cands
  }
  # compdef comes from compinit, so awsp has to be sourced after it (the end of ~/.zshrc is fine).
  if command -v compdef >/dev/null 2>&1; then compdef _awsp_zsh_complete awsp; fi
else
  _awsp_complete() {
    local cur=${COMP_WORDS[COMP_CWORD]} c
    COMPREPLY=()
    while IFS= read -r c; do COMPREPLY+=("$c"); done < <(
      compgen -W "$(_awsp_candidates "$COMP_CWORD" "${COMP_WORDS[1]:-}")" -- "$cur")
  }
  complete -F _awsp_complete awsp
fi
