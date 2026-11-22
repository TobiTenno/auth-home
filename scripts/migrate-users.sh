#!/usr/bin/env bash
# Seed LLDAP users from tak-home (USERS + optional USER_PASS_*).
#
#   ./scripts/migrate-users.sh --bind-only
#   ./scripts/migrate-users.sh --tak-home ../tak-home --dry-run
#   ./scripts/migrate-users.sh --tak-home ../tak-home --migrate-plaintext-pass
#   ./scripts/migrate-users.sh --tak-home ../tak-home --email-domain example.com
#   ./scripts/migrate-users.sh --users-file ./users.tsv --migrate-plaintext-pass
#
# --migrate-plaintext-pass
#   "I have plaintext passwords from an old version" — read USER_PASS_* from
#   tak-home config/secrets.env (or PASS column in --users-file) and set those
#   as the initial LLDAP passwords. Without this flag, random temps are used
#   (printed once) unless --no-passwords.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"

tak_home=""
users_file=""
email_domain=""
migrate_plaintext=0
dry_run=0
no_passwords=0
ensure_groups=1
bind_only=0
# Only used when --lldap-url is set (e.g. --no-swag host ports). Default = docker network.
lldap_url="${LLDAP_URL:-}"
lldap_ctr=auth_lldap
auth_net=auth

usage() {
  cat <<'EOF'
Usage: ./scripts/migrate-users.sh --bind-only
       ./scripts/migrate-users.sh --tak-home PATH [options]
       ./scripts/migrate-users.sh --users-file PATH [options]

  --bind-only                  Create Authelia LDAP bind user + default groups only
  --tak-home PATH              tak-home deploy/src with config/takserver.env + secrets.env
  --users-file PATH            TSV: username<TAB>email[<TAB>password] (password optional)
  --email-domain DOMAIN        If no email map: user -> user@DOMAIN
  --migrate-plaintext-pass     Use USER_PASS_* / TSV password column as initial LLDAP passwords
  --no-passwords               Create users without setting a password
  --dry-run                    Print actions only
  --lldap-url URL              Host URL only if LLDAP ports published (--no-swag).
                               Default: talk via docker exec / network auth (no host ports)
  --skip-groups                Do not ensure default groups

Requires config/*.env (from ./setup.sh). Talks to LLDAP GraphQL as admin.
Start auth_lldap first; run --bind-only before starting auth_authelia.
EOF
}

while [[ $# -gt 0 ]]; do
  case $1 in
    --tak-home) tak_home=$2; shift 2 ;;
    --users-file) users_file=$2; shift 2 ;;
    --email-domain) email_domain=$2; shift 2 ;;
    --migrate-plaintext-pass) migrate_plaintext=1; shift ;;
    --no-passwords) no_passwords=1; shift ;;
    --bind-only) bind_only=1; shift ;;
    --dry-run) dry_run=1; shift ;;
    --lldap-url) lldap_url=$2; shift 2 ;;
    --skip-groups) ensure_groups=0; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 1 ;;
  esac
done

[[ $bind_only -eq 1 || -n $tak_home || -n $users_file ]] || { usage; exit 1; }
[[ -f config/common.env && -f config/lldap.env ]] || {
  echo "Missing config/*.env — run ./setup.sh first" >&2
  exit 1
}

# shellcheck disable=SC1091
set -a
source config/common.env
source config/lldap.env
[[ -f config/authelia.secrets.env ]] && source config/authelia.secrets.env
set +a

ADMIN_USER=admin
# Trim CR/LF from env files (CRLF → opaque/LDAP weirdness)
ADMIN_PASS=$(printf '%s' "${LLDAP_LDAP_USER_PASS:?}" | tr -d '\r\n')
BASE_DN=${LLDAP_BASE_DN:-${LLDAP_LDAP_BASE_DN:?}}
BASE_DN=$(printf '%s' "$BASE_DN" | tr -d '\r\n')
auth_net=${AUTH_NETWORK_AUTH:-auth}
LLDAP_AUTHELIA_PASSWORD=$(printf '%s' "${LLDAP_AUTHELIA_PASSWORD:-}" | tr -d '\r\n')

lldap_running() {
  docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$lldap_ctr"
}

# HTTP to LLDAP without host ports:
#   1) docker exec into auth_lldap (127.0.0.1 *inside* that container)
#   2) else one-shot curl on Docker network "auth" → http://auth_lldap:17170
#   3) else --lldap-url / LLDAP_URL (only when ports published)
lldap_http() {
  # usage: lldap_http METHOD PATH [json-body] [bearer-token]
  local method=$1 path=$2 body=${3:-} token=${4:-}
  local url headers=(-H "Content-Type: application/json")
  [[ -n $token ]] && headers+=(-H "Authorization: Bearer $token")

  if lldap_running; then
    # busybox wget inside image; 127.0.0.1 is loopback *in* the container
    local wd=(-qO-)
    wd+=(--header="Content-Type: application/json")
    [[ -n $token ]] && wd+=(--header="Authorization: Bearer $token")
    if [[ $method == POST || -n $body ]]; then
      wd+=(--post-data="$body")
    fi
    docker exec -i "$lldap_ctr" wget "${wd[@]}" "http://127.0.0.1:17170${path}"
    return
  fi

  if docker network inspect "$auth_net" >/dev/null 2>&1; then
    # One-shot on the auth network — no host publish required
    if [[ -n $body ]]; then
      docker run --rm --network "$auth_net" curlimages/curl:8.5.0 \
        -fsS -X "$method" "${headers[@]}" -d "$body" "http://${lldap_ctr}:17170${path}"
    else
      docker run --rm --network "$auth_net" curlimages/curl:8.5.0 \
        -fsS -X "$method" "${headers[@]}" "http://${lldap_ctr}:17170${path}"
    fi
    return
  fi

  if [[ -n $lldap_url ]]; then
    if [[ -n $body ]]; then
      curl -fsS -X "$method" "${headers[@]}" -d "$body" "${lldap_url}${path}"
    else
      curl -fsS -X "$method" "${headers[@]}" "${lldap_url}${path}"
    fi
    return
  fi

  echo "LLDAP unreachable: start $lldap_ctr (no host ports) or pass --lldap-url for --no-swag" >&2
  return 1
}

graphql() {
  local body=$1
  lldap_http POST /api/graphql "$body" "$TOKEN"
}

login() {
  local resp body
  body=$(U="$ADMIN_USER" P="$ADMIN_PASS" python3 -c \
    'import json,os; print(json.dumps({"username":os.environ["U"],"password":os.environ["P"]}))')
  resp=$(lldap_http POST /auth/simple/login "$body") || {
    echo "LLDAP login request failed" >&2
    exit 1
  }
  TOKEN=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["token"])' <<<"$resp")
  [[ -n $TOKEN ]] || { echo "LLDAP login failed: $resp" >&2; exit 1; }
  if lldap_running; then
    echo "LLDAP:      via docker exec $lldap_ctr"
  elif [[ -n $lldap_url ]]; then
    echo "LLDAP:      via $lldap_url"
  else
    echo "LLDAP:      via network $auth_net → $lldap_ctr"
  fi
}

json_escape() {
  python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()[:-1] if False else sys.argv[1]))' "$1"
}

ensure_group() {
  local g=$1
  local q
  q=$(printf '{"query":"mutation { createGroup(name: %s) { id displayName } }"}' "$(json_escape "$g")")
  if [[ $dry_run -eq 1 ]]; then
    echo "DRY group: $g"
    return 0
  fi
  graphql "$q" >/dev/null 2>&1 || true
}

create_user() {
  local user=$1 email=$2
  local q
  q=$(printf '{"query":"mutation { createUser(user: { id: %s, email: %s }) { id email } }"}' \
    "$(json_escape "$user")" "$(json_escape "$email")")
  if [[ $dry_run -eq 1 ]]; then
    echo "DRY user:  $user <$email>"
    return 0
  fi
  if ! graphql "$q" >/dev/null 2>&1; then
    echo "note: createUser $user may already exist"
  fi
}

add_to_group() {
  local user=$1 group=$2
  local gid q resp
  if [[ $dry_run -eq 1 ]]; then
    echo "DRY member: $user → $group"
    return 0
  fi
  resp=$(graphql '{"query":"{ groups { id displayName } }"}' 2>/dev/null || true)
  gid=$(GROUP_NAME="$group" python3 -c '
import json, os, sys
try:
  data = json.load(sys.stdin)
  name = os.environ["GROUP_NAME"]
  for g in data.get("data", {}).get("groups", []) or []:
    if g.get("displayName") == name:
      print(g["id"])
      break
except Exception:
  pass
' <<<"$resp")
  [[ -n ${gid:-} ]] || return 0
  q=$(printf '{"query":"mutation { addUserToGroup(userId: %s, groupId: %s) { ok } }"}' \
    "$(json_escape "$user")" "$gid")
  graphql "$q" >/dev/null 2>&1 || true
}

set_password_opaque() {
  local user=$1 pass=$2
  local out err=0
  # Prefer JWT we already have; pass via env to avoid shell/`!` quirks
  local args=(exec -e "LLDAP_USER_PASSWORD=$pass" "$lldap_ctr" /app/lldap_set_password
    --base-url http://127.0.0.1:17170 --username "$user")
  if [[ -n ${TOKEN:-} ]]; then
    args+=(--token "$TOKEN")
  else
    args+=(--admin-username "$ADMIN_USER" --admin-password "$ADMIN_PASS")
  fi
  set +e
  out=$(docker "${args[@]}" 2>&1)
  err=$?
  set -e
  if [[ $err -eq 0 ]]; then
    echo "pass:      $user ok (opaque)"
    return 0
  fi
  echo "pass:      $user opaque failed: $out" >&2
  return 1
}

# Fallback when opaque register/start returns 400 (seen on some LLDAP states)
set_password_ldap() {
  local user=$1 pass=$2
  local dn="uid=${user},ou=people,${BASE_DN}"
  local admin_dn="uid=${ADMIN_USER},ou=people,${BASE_DN}"
  local out err=0
  if ! docker network inspect "$auth_net" >/dev/null 2>&1; then
    echo "pass:      $user ldap fallback needs docker network $auth_net" >&2
    return 1
  fi
  set +e
  out=$(docker run --rm --network "$auth_net" \
    -e "LDAP_ADMIN_DN=$admin_dn" -e "LDAP_ADMIN_PW=$ADMIN_PASS" \
    -e "LDAP_USER_DN=$dn" -e "LDAP_USER_PW=$pass" -e "LDAP_HOST=$lldap_ctr" \
    alpine:3.19 sh -c '
      apk add --no-cache openldap-clients >/dev/null
      ldappasswd -x -H "ldap://${LDAP_HOST}:3890" \
        -D "$LDAP_ADMIN_DN" -w "$LDAP_ADMIN_PW" \
        -s "$LDAP_USER_PW" "$LDAP_USER_DN"
    ' 2>&1)
  err=$?
  set -e
  if [[ $err -eq 0 ]]; then
    echo "pass:      $user ok (ldap)"
    return 0
  fi
  echo "pass:      $user ldap failed: $out" >&2
  return 1
}

set_password() {
  local user=$1 pass=$2
  pass=$(printf '%s' "$pass" | tr -d '\r\n')
  if [[ $dry_run -eq 1 ]]; then
    echo "DRY pass:  $user"
    return 0
  fi
  if lldap_running && set_password_opaque "$user" "$pass"; then
    return 0
  fi
  if set_password_ldap "$user" "$pass"; then
    return 0
  fi
  echo "$user	$pass" >> "$root/config/secrets/pending-passwords.tsv"
  return 1
}

delete_user() {
  local user=$1
  local q
  q=$(printf '{"query":"mutation { deleteUser(userId: %s) { ok } }"}' "$(json_escape "$user")")
  if [[ $dry_run -eq 1 ]]; then
    echo "DRY delete: $user"
    return 0
  fi
  graphql "$q" >/dev/null 2>&1 || true
}

# Confirm Authelia can authenticate as the bind user (simple login)
verify_bind() {
  local pass=$1 resp body
  if [[ $dry_run -eq 1 ]]; then
    echo "DRY verify: authelia bind"
    return 0
  fi
  body=$(U=authelia P="$pass" python3 -c \
    'import json,os; print(json.dumps({"username":os.environ["U"],"password":os.environ["P"]}))')
  set +e
  resp=$(lldap_http POST /auth/simple/login "$body" 2>&1)
  set -e
  if python3 -c 'import json,sys; json.load(sys.stdin)["token"]' <<<"$resp" 2>/dev/null; then
    echo "verify:    authelia bind login ok"
    return 0
  fi
  echo "verify:    authelia bind login FAILED: $resp" >&2
  return 1
}

# Collect users: username email password(optional)
declare -a ROWS=()

if [[ $bind_only -eq 0 ]]; then
  if [[ -n $users_file ]]; then
    while IFS=$'\t' read -r u e p || [[ -n ${u:-} ]]; do
      [[ -z ${u:-} || $u == \#* ]] && continue
      ROWS+=("$u	${e:-}	${p:-}")
    done < "$users_file"
  fi

  if [[ -n $tak_home ]]; then
    tak_home=$(cd "$tak_home" && pwd)
    ts=$tak_home/config/takserver.env
    sec=$tak_home/config/secrets.env
    [[ -f $ts ]] || { echo "Missing $ts" >&2; exit 1; }
    # shellcheck disable=SC1090
    set -a; source "$ts"; set +a
    if [[ -f $sec ]]; then
      # shellcheck disable=SC1090
      set -a; source "$sec"; set +a
    fi
    email_domain=${email_domain:-${DOMAIN:-}}
    for user in ${USERS:-}; do
      key="USER_PASS_$(echo "$user" | tr '[:lower:]-' '[:upper:]_')"
      pass=${!key:-}
      if [[ -n $email_domain ]]; then
        email="${user}@${email_domain}"
      else
        email=$user
      fi
      ROWS+=("$user	$email	$pass")
    done
  fi

  [[ ${#ROWS[@]} -gt 0 ]] || { echo "No users found" >&2; exit 1; }
fi

[[ -n ${LLDAP_AUTHELIA_PASSWORD:-} ]] || {
  echo "Missing LLDAP_AUTHELIA_PASSWORD (config/common.env or authelia.secrets.env)" >&2
  exit 1
}

if [[ $bind_only -eq 1 ]]; then
  echo "Mode: bind-only (Authelia LDAP user + groups)"
else
  echo "Users: ${#ROWS[@]}"
  echo "Plaintext migrate: $([[ $migrate_plaintext -eq 1 ]] && echo yes || echo no)"
fi
echo "Dry-run: $([[ $dry_run -eq 1 ]] && echo yes || echo no)"

if [[ $dry_run -eq 0 ]]; then
  login
fi

if [[ $ensure_groups -eq 1 ]]; then
  for g in cloudtak_users authelia_users tak_admins lldap_admin authelia_user_manager; do
    ensure_group "$g"
  done
fi

: > "$root/config/secrets/pending-passwords.tsv" 2>/dev/null || true
umask 077

if [[ $bind_only -eq 0 ]]; then
  for row in "${ROWS[@]}"; do
    IFS=$'\t' read -r user email pass <<<"$row"
    [[ -n $email ]] || email=$user
    # LLDAP id: prefer email local-part sanitized, or username
    id=$(echo "$user" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9._-' '-' | sed 's/^-//;s/-$//')
    create_user "$id" "$email"
    add_to_group "$id" "cloudtak_users"
    add_to_group "$id" "authelia_users"

    if [[ $no_passwords -eq 1 ]]; then
      echo "user:      $id <$email> (no password)"
      continue
    fi

    if [[ $migrate_plaintext -eq 1 && -n ${pass:-} ]]; then
      set_password "$id" "$pass"
      echo "user:      $id <$email> password=seeded"
    elif [[ $migrate_plaintext -eq 1 && -z ${pass:-} ]]; then
      tmp="Temp!$(openssl rand -hex 6)"
      set_password "$id" "$tmp"
      echo "user:      $id <$email> password=TEMP (no USER_PASS_*): $tmp"
    else
      tmp="Temp!$(openssl rand -hex 6)"
      set_password "$id" "$tmp"
      echo "user:      $id <$email> password=TEMP: $tmp"
    fi
  done
fi

# Ensure Authelia bind user exists (required before auth_authelia can start)
bind_ok=1
if [[ $dry_run -eq 0 ]]; then
  # Fresh bind user avoids stuck OPAQUE state → register/start 400
  delete_user "authelia"
  create_user "authelia" "authelia@${DOMAIN:-localhost}"
  if ! set_password "authelia" "$LLDAP_AUTHELIA_PASSWORD"; then
    bind_ok=0
  elif ! verify_bind "$LLDAP_AUTHELIA_PASSWORD"; then
    bind_ok=0
  else
    echo "bind:      authelia ready (must match configuration.yml ldap.password)"
  fi
fi

echo "Done."
if [[ -s $root/config/secrets/pending-passwords.tsv ]]; then
  echo "Some passwords queued in config/secrets/pending-passwords.tsv"
fi
if [[ $bind_ok -eq 0 ]]; then
  echo "FATAL: Authelia bind user password not set — auth_authelia will exit with LDAP 49" >&2
  exit 1
fi
exit 0
