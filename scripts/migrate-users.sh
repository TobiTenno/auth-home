#!/usr/bin/env bash
# Seed LLDAP users from tak-home (USERS + optional USER_PASS_*).
#
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
lldap_url="${LLDAP_URL:-http://127.0.0.1:17170}"

usage() {
  cat <<'EOF'
Usage: ./scripts/migrate-users.sh --tak-home PATH [options]
       ./scripts/migrate-users.sh --users-file PATH [options]

  --tak-home PATH              tak-home deploy/src with config/takserver.env + secrets.env
  --users-file PATH            TSV: username<TAB>email[<TAB>password] (password optional)
  --email-domain DOMAIN        If no email map: user -> user@DOMAIN
  --migrate-plaintext-pass     Use USER_PASS_* / TSV password column as initial LLDAP passwords
  --no-passwords               Create users without setting a password
  --dry-run                    Print actions only
  --lldap-url URL              Default http://127.0.0.1:17170 (or docker exec path)
  --skip-groups                Do not ensure default groups

Requires config/auth.env (from ./setup.sh). Talks to LLDAP GraphQL as admin.
EOF
}

while [[ $# -gt 0 ]]; do
  case $1 in
    --tak-home) tak_home=$2; shift 2 ;;
    --users-file) users_file=$2; shift 2 ;;
    --email-domain) email_domain=$2; shift 2 ;;
    --migrate-plaintext-pass) migrate_plaintext=1; shift ;;
    --no-passwords) no_passwords=1; shift ;;
    --dry-run) dry_run=1; shift ;;
    --lldap-url) lldap_url=$2; shift 2 ;;
    --skip-groups) ensure_groups=0; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 1 ;;
  esac
done

[[ -n $tak_home || -n $users_file ]] || { usage; exit 1; }
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
ADMIN_PASS=${LLDAP_LDAP_USER_PASS:?}
BASE_DN=${LLDAP_BASE_DN:-${LLDAP_LDAP_BASE_DN:?}}

# Prefer docker exec into lldap when URL is loopback and container is up
graphql() {
  local body=$1
  if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx auth_lldap; then
    docker exec -i auth_lldap wget -qO- \
      --header="Content-Type: application/json" \
      --header="Authorization: Bearer $TOKEN" \
      --post-data="$body" \
      http://127.0.0.1:17170/api/graphql
  else
    curl -fsS -H "Content-Type: application/json" -H "Authorization: Bearer $TOKEN" \
      -d "$body" "$lldap_url/api/graphql"
  fi
}

login() {
  local resp
  if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx auth_lldap; then
    resp=$(docker exec -i auth_lldap wget -qO- \
      --header="Content-Type: application/json" \
      --post-data="{\"username\":\"$ADMIN_USER\",\"password\":\"$ADMIN_PASS\"}" \
      http://127.0.0.1:17170/auth/simple/login)
  else
    resp=$(curl -fsS -H "Content-Type: application/json" \
      -d "{\"username\":\"$ADMIN_USER\",\"password\":\"$ADMIN_PASS\"}" \
      "$lldap_url/auth/simple/login")
  fi
  TOKEN=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["token"])' <<<"$resp")
  [[ -n $TOKEN ]] || { echo "LLDAP login failed" >&2; exit 1; }
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

set_password() {
  local user=$1 pass=$2
  if [[ $dry_run -eq 1 ]]; then
    echo "DRY pass:  $user"
    return 0
  fi
  # lldap_set_password via docker if present; else HTTP register is complex — use ldap modify through container
  if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx auth_lldap; then
    if docker exec auth_lldap /app/lldap_set_password --base-url http://127.0.0.1:17170 \
      --admin-username "$ADMIN_USER" --admin-password "$ADMIN_PASS" \
      --username "$user" --password "$pass" 2>/dev/null; then
      return 0
    fi
  fi
  # Fallback: write to a one-shot list for the operator
  echo "$user	$pass" >> "$root/config/secrets/pending-passwords.tsv"
  echo "pass:      $user queued in config/secrets/pending-passwords.tsv (set via LLDAP UI or lldap_set_password)"
}

# Collect users: username email password(optional)
declare -a ROWS=()

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

echo "Users: ${#ROWS[@]}"
echo "Plaintext migrate: $([[ $migrate_plaintext -eq 1 ]] && echo yes || echo no)"
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

# Ensure Authelia bind user exists
if [[ $dry_run -eq 0 ]]; then
  create_user "authelia" "authelia@${DOMAIN:-localhost}"
  set_password "authelia" "$LLDAP_AUTHELIA_PASSWORD"
  echo "bind:      authelia (LLDAP_AUTHELIA_PASSWORD from auth.env)"
fi

echo "Done."
if [[ -s $root/config/secrets/pending-passwords.tsv ]]; then
  echo "Some passwords queued in config/secrets/pending-passwords.tsv"
fi
exit 0
