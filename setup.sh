#!/usr/bin/env bash
# Generate auth-home config for a parent domain.
#   ./setup.sh example.com
#   ./setup.sh -h example.com --admin-expose tailscale
#   ./setup.sh example.com -f ../docker-compose.yml
#   ./setup.sh example.com --no-swag
#
# -f copies this stack next to the compose file (like tak-home), then
# includes auth-home/compose.yaml and wires networks onto SWAG.
set -euo pipefail

src=$(cd "$(dirname "$0")" && pwd)

domain=""
admin_expose=subnet
compose_file=""
force=0
no_swag=0
swag_service=swag

usage() {
  cat <<'EOF'
Usage: ./setup.sh <domain> [options]
       ./setup.sh -h <domain> [options]

  --admin-expose MODE   subnet|localhost|tailscale|public (default: subnet)
  -f, --file PATH       Shared root compose: copy stack beside it as auth-home/,
                        include compose.yaml, add networks, attach SWAG
  --swag-service NAME   Service to attach networks to (default: swag)
  --no-swag             Publish host ports via compose.no-swag.yaml (no SWAG proxy)
  --force               Regenerate Authelia OIDC JWKS even if present
EOF
}

while [[ $# -gt 0 ]]; do
  case $1 in
    -h|--host) domain=$2; shift 2 ;;
    --admin-expose) admin_expose=$2; shift 2 ;;
    -f|--file) compose_file=$2; shift 2 ;;
    --file=*) compose_file=${1#--file=}; [[ -n $compose_file ]] || { echo "--file needs a path" >&2; exit 1; }; shift ;;
    --swag-service) swag_service=$2; shift 2 ;;
    --no-swag) no_swag=1; shift ;;
    --force) force=1; shift ;;
    -*) echo "Unknown option: $1" >&2; usage; exit 1 ;;
    *) domain=$1; shift ;;
  esac
done

[[ -n $domain ]] || { usage; exit 1; }
[[ $domain == *.* ]] || { echo "Domain should look like example.com" >&2; exit 1; }

case $admin_expose in
  subnet|localhost|tailscale|public) ;;
  *) echo "ADMIN_EXPOSE must be subnet|localhost|tailscale|public" >&2; exit 1 ;;
esac

if [[ -n $compose_file ]]; then
  [[ -d $(dirname "$compose_file") ]] || {
    echo "Compose parent dir missing: $(dirname "$compose_file")" >&2
    exit 1
  }
  compose_file=$(cd "$(dirname "$compose_file")" && pwd)/$(basename "$compose_file")
  root=$(dirname "$compose_file")/auth-home
else
  root=$src
fi

if [[ $root != "$src" ]]; then
  # Runtime only — templates stay in the authoring/git tree ($src)
  mkdir -p "$root/config/authelia" "$root/config/secrets" "$root/swag" "$root/scripts" \
    "$root/data/lldap" "$root/data/authelia"
  cp "$src/compose.yaml" "$src/compose.no-swag.yaml" "$src/setup.sh" "$src/README.md" "$root/"
  cp "$src/scripts/migrate-users.sh" "$root/scripts/"
  chmod +x "$root/setup.sh" "$root/scripts/migrate-users.sh"
  # Drop leftover authoring bits from older deploys
  rm -rf "$root/templates" "$root/docs"
  rm -f "$root/config/"*.template "$root/swag/"*.template "$root/config/auth.env.template"
  echo "Deploy:     runtime → $root (templates read from $src)"
fi

cd "$root"

# Template sources: authoring tree when deploying with -f, else this tree
tmpl_root=$src
[[ -f $tmpl_root/templates/authelia.configuration.yml.template ]] || {
  echo "Missing templates under $tmpl_root — run setup from the git/authoring clone" >&2
  exit 1
}

domain_dc=$(python3 -c "print(','.join('dc='+p for p in '${domain}'.split('.')))")

rand() { openssl rand -hex "${1:-16}"; }
rand_pass() { echo "Auth!$(openssl rand -hex 8)"; }

mkdir -p config/authelia config/secrets swag data/lldap data/authelia

# Preserve secrets across re-runs
load_env() {
  local f=$1
  [[ -f $f ]] || return 0
  set -a
  # shellcheck disable=SC1090
  source "$f"
  set +a
}
load_env config/common.env
load_env config/lldap.env
load_env config/authelia.env
load_env config/authelia.secrets.env
load_env config/authelia-admin.env
# legacy single file
load_env config/auth.env

LLDAP_ADMIN_PASSWORD=${LLDAP_ADMIN_PASSWORD:-${LLDAP_LDAP_USER_PASS:-$(rand_pass)}}
LLDAP_JWT_SECRET=${LLDAP_JWT_SECRET:-$(rand 32)}
LLDAP_AUTHELIA_PASSWORD=${LLDAP_AUTHELIA_PASSWORD:-$(rand_pass)}
AUTHELIA_JWT_SECRET=${AUTHELIA_JWT_SECRET:-$(rand 32)}
AUTHELIA_SESSION_SECRET=${AUTHELIA_SESSION_SECRET:-$(rand 32)}
AUTHELIA_STORAGE_ENCRYPTION_KEY=${AUTHELIA_STORAGE_ENCRYPTION_KEY:-$(rand 32)}
AUTHELIA_OIDC_HMAC_SECRET=${AUTHELIA_OIDC_HMAC_SECRET:-$(rand 32)}
OIDC_CLOUDTAK_CLIENT_SECRET=${OIDC_CLOUDTAK_CLIENT_SECRET:-$(rand 24)}
AUTH_NETWORK=${AUTH_NETWORK:-tak}

fill() {
  local tmpl=$1 dst=$2
  umask 077
  sed \
    -e "s|@DOMAIN@|$domain|g" \
    -e "s|@DOMAIN_DC@|$domain_dc|g" \
    -e "s|@ADMIN_EXPOSE@|$admin_expose|g" \
    -e "s|@NO_SWAG@|$no_swag|g" \
    -e "s|@LLDAP_ADMIN_PASSWORD@|$LLDAP_ADMIN_PASSWORD|g" \
    -e "s|@LLDAP_JWT_SECRET@|$LLDAP_JWT_SECRET|g" \
    -e "s|@LLDAP_AUTHELIA_PASSWORD@|$LLDAP_AUTHELIA_PASSWORD|g" \
    "$tmpl" > "$dst"
  umask 022
}

fill "$tmpl_root/config/common.env.template" config/common.env
# append secrets not in template
{
  cat config/common.env
  cat <<EOF
LLDAP_AUTHELIA_PASSWORD=$LLDAP_AUTHELIA_PASSWORD
OIDC_CLOUDTAK_CLIENT_SECRET=$OIDC_CLOUDTAK_CLIENT_SECRET
AUTH_NETWORK=$AUTH_NETWORK
EOF
} > config/common.env.tmp && mv config/common.env.tmp config/common.env
chmod 600 config/common.env

fill "$tmpl_root/config/lldap.env.template" config/lldap.env
chmod 600 config/lldap.env

fill "$tmpl_root/config/authelia.env.template" config/authelia.env

fill "$tmpl_root/config/authelia-admin.env.template" config/authelia-admin.env
chmod 600 config/authelia-admin.env

# Keep LLDAP_AUTHELIA_PASSWORD available for Authelia YAML
export LLDAP_AUTHELIA_PASSWORD

jwks=config/authelia/oidc.pem
if [[ ! -f $jwks || $force -eq 1 ]]; then
  openssl genrsa -out "$jwks" 2048
  chmod 600 "$jwks"
  echo "OIDC JWKS:  wrote $jwks"
fi

oidc_hash=""
if docker image inspect authelia/authelia:latest >/dev/null 2>&1 \
  || docker pull authelia/authelia:latest >/dev/null 2>&1; then
  oidc_hash=$(docker run --rm authelia/authelia:latest \
    authelia crypto hash generate pbkdf2 --password "$OIDC_CLOUDTAK_CLIENT_SECRET" 2>/dev/null \
    | awk '/Digest:/ {print $2; exit}')
fi
if [[ -z ${oidc_hash:-} ]]; then
  oidc_hash="\$plaintext\$$OIDC_CLOUDTAK_CLIENT_SECRET"
  echo "OIDC hash:  using \$plaintext\$ (pull authelia image for pbkdf2)"
else
  echo "OIDC hash:  pbkdf2 digest ready"
fi

export DOMAIN=$domain
export AUTH_HOST=auth.$domain
export LLDAP_BASE_DN=$domain_dc
export LLDAP_AUTHELIA_DN=uid=authelia,ou=people,$domain_dc
export AUTHELIA_JWT_SECRET AUTHELIA_SESSION_SECRET
export AUTHELIA_STORAGE_ENCRYPTION_KEY AUTHELIA_OIDC_HMAC_SECRET
export OIDC_CLOUDTAK_CLIENT_ID=cloudtak
export OIDC_CLOUDTAK_REDIRECT=https://map.$domain/api/login/oidc/callback
export OIDC_HASH=$oidc_hash
export JWKS_INDENTED
JWKS_INDENTED=$(sed 's/^/          /' "$jwks")

python3 - "$tmpl_root/templates/authelia.configuration.yml.template" \
  "$root/config/authelia/configuration.yml" <<'PY'
import pathlib, sys, os
tmpl, out = sys.argv[1], sys.argv[2]
text = pathlib.Path(tmpl).read_text()
repl = {
  "AUTHELIA_JWT_SECRET": os.environ["AUTHELIA_JWT_SECRET"],
  "AUTHELIA_SESSION_SECRET": os.environ["AUTHELIA_SESSION_SECRET"],
  "AUTHELIA_STORAGE_ENCRYPTION_KEY": os.environ["AUTHELIA_STORAGE_ENCRYPTION_KEY"],
  "AUTHELIA_OIDC_HMAC_SECRET": os.environ["AUTHELIA_OIDC_HMAC_SECRET"],
  "LLDAP_BASE_DN": os.environ["LLDAP_BASE_DN"],
  "LLDAP_AUTHELIA_DN": os.environ["LLDAP_AUTHELIA_DN"],
  "LLDAP_AUTHELIA_PASSWORD": os.environ["LLDAP_AUTHELIA_PASSWORD"],
  "AUTH_HOST": os.environ["AUTH_HOST"],
  "DOMAIN": os.environ["DOMAIN"],
  "OIDC_CLOUDTAK_CLIENT_ID": os.environ.get("OIDC_CLOUDTAK_CLIENT_ID", "cloudtak"),
  "OIDC_CLOUDTAK_CLIENT_SECRET_HASHED": os.environ["OIDC_HASH"],
  "OIDC_CLOUDTAK_REDIRECT": os.environ["OIDC_CLOUDTAK_REDIRECT"],
  "OIDC_JWKS_KEY_INDENTED": os.environ["JWKS_INDENTED"],
}
for k, v in repl.items():
  text = text.replace("{{" + k + "}}", v)
pathlib.Path(out).write_text(text)
print(f"Authelia:   wrote {out}")
PY

# Persist Authelia secrets for re-runs (not in env templates)
umask 077
cat > config/authelia.secrets.env <<EOF
AUTHELIA_JWT_SECRET=$AUTHELIA_JWT_SECRET
AUTHELIA_SESSION_SECRET=$AUTHELIA_SESSION_SECRET
AUTHELIA_STORAGE_ENCRYPTION_KEY=$AUTHELIA_STORAGE_ENCRYPTION_KEY
AUTHELIA_OIDC_HMAC_SECRET=$AUTHELIA_OIDC_HMAC_SECRET
OIDC_CLOUDTAK_CLIENT_SECRET=$OIDC_CLOUDTAK_CLIENT_SECRET
LLDAP_AUTHELIA_PASSWORD=$LLDAP_AUTHELIA_PASSWORD
EOF
umask 022

python3 - "$admin_expose" "$domain" "$tmpl_root/swag/auth.conf.template" "$root/swag/auth.conf" <<'PY'
import pathlib, sys
mode, domain, tmpl, out = sys.argv[1:5]
auth_host = f"auth.{domain}"
blocks = {
  "subnet": """    allow 10.0.0.0/8;
    allow 172.16.0.0/12;
    allow 192.168.0.0/16;
    allow 127.0.0.0/8;
    deny all;""",
  "localhost": """    allow 127.0.0.1;
    allow ::1;
    deny all;""",
  "tailscale": """    allow 100.64.0.0/10;
    allow 127.0.0.0/8;
    deny all;""",
  "public": "    # ADMIN_EXPOSE=public — no IP allowlist",
}
allow = blocks[mode]
text = pathlib.Path(tmpl).read_text()
text = (
  text.replace("@AUTH_HOST@", auth_host)
      .replace("@ADMIN_ALLOW@", allow)
      .replace("@ADMIN_EXPOSE@", mode)
)
pathlib.Path(out).write_text(text)
print(f"SWAG:       wrote {out} (ADMIN_EXPOSE={mode})")
PY

if [[ $no_swag -eq 1 ]]; then
  echo "NO_SWAG:    use -f compose.yaml -f compose.no-swag.yaml for host ports"
  printf '1\n' > .no-swag
else
  rm -f .no-swag
fi

# Wire root compose: include + networks auth/tak + attach SWAG
if [[ -n $compose_file ]]; then
  printf '%s\n' "$compose_file" > .compose-file
  python3 - "$compose_file" "$root/compose.yaml" "$swag_service" "${AUTH_NETWORK:-tak}" <<'PY'
import os, sys, re

compose_file, included, swag_svc, tak_net = sys.argv[1:5]
compose_file = os.path.abspath(compose_file)
included = os.path.abspath(included)
base = os.path.dirname(compose_file)
rel = os.path.relpath(included, base).replace(os.sep, "/")
text = open(compose_file).read() if os.path.exists(compose_file) else ""
before = text

def already_includes(src: str, path: str) -> bool:
    # path: auth-home/compose.yaml  OR  - auth-home/compose.yaml  OR quoted
    esc = re.escape(path)
    return bool(
        re.search(rf'(?m)^\s*-\s*path:\s*"?{esc}"?\s*$', src)
        or re.search(rf'(?m)^\s*-\s*"?{esc}"?\s*$', src)
    )

# --- include ---
item = f"  - path: {rel}\n"
if already_includes(text, rel):
    print(f"Compose:     already includes {rel}")
elif not text.strip():
    text = f"include:\n{item}"
    print(f"Compose:     created include {rel}")
elif re.search(r"(?m)^include:\s*$", text):
    lines = text.splitlines(keepends=True)
    out, inserted = [], False
    for line in lines:
        out.append(line)
        if not inserted and re.match(r"^include:\s*$", line):
            out.append(item)
            inserted = True
    text = "".join(out)
    print(f"Compose:     included {rel}")
else:
    if not text.endswith("\n"):
        text += "\n"
    text = f"include:\n{item}\n{text}"
    print(f"Compose:     prepended include {rel}")

# --- top-level networks: auth + tak (both external — shared across projects) ---
def ensure_networks(src: str) -> str:
    auth_block = (
        "  auth:\n"
        "    name: auth\n"
        "    external: true\n"
    )
    tak_block = (
        f"  {tak_net}:\n"
        f"    name: {tak_net}\n"
        "    external: true\n"
    )
    # Upgrade existing auth: missing external: true (causes WARN under shared root project)
    if re.search(r"(?m)^  auth:\s*$", src) and not re.search(
        r"(?m)^  auth:\s*\n(?:    .*\n)*?    external:\s*true\s*$", src
    ):
        src = re.sub(
            r"(?m)^(  auth:\s*\n(?:    name:\s*auth\s*\n)?)",
            r"\1    external: true\n",
            src,
            count=1,
        )
        print("Compose:     auth network → external: true")
    if re.search(r"(?m)^networks:\s*$", src):
        m = re.search(r"(?m)^networks:\s*\n", src)
        assert m
        insert_at = m.end()
        chunk = ""
        if not re.search(r"(?m)^  auth:\s*$", src):
            chunk += auth_block
        if not re.search(rf"(?m)^  {re.escape(tak_net)}:\s*$", src):
            chunk += tak_block
        if chunk:
            src = src[:insert_at] + chunk + src[insert_at:]
            print(f"Compose:     networks += auth / {tak_net}")
        else:
            print("Compose:     networks auth/tak already present")
        return src
    if not src.endswith("\n"):
        src += "\n"
    src += "\nnetworks:\n" + auth_block + tak_block
    print(f"Compose:     appended networks auth / {tak_net}")
    return src

text = ensure_networks(text)

# --- attach SWAG (or named service) to auth + tak ---
svc = swag_svc
pat = re.compile(rf"(?m)^  {re.escape(svc)}:\s*$")
m = pat.search(text)
if not m:
    print(f"Compose:     no service '{svc}' — add networks: [auth, {tak_net}] manually")
else:
    rest = text[m.end():]
    end_rel = len(rest)
    for nm in re.finditer(r"(?m)^  [A-Za-z0-9_-]+:\s*$", rest):
        end_rel = nm.start()
        break
    block = rest[:end_rel]
    if re.search(rf"(?m)^\s+-\s*{re.escape(tak_net)}\s*$", block) and re.search(r"(?m)^\s+-\s*auth\s*$", block):
        print(f"Compose:     {svc} already on auth + {tak_net}")
    elif re.search(r"(?m)^    networks:\s*$", block):
        def add_net(b, name):
            if re.search(rf"(?m)^\s+-\s*{re.escape(name)}\s*$", b):
                return b
            return re.sub(
                r"(?m)^(    networks:\s*\n)",
                rf"\1      - {name}\n",
                b,
                count=1,
            )
        new_block = add_net(add_net(block, "auth"), tak_net)
        text = text[: m.end()] + new_block + rest[end_rel:]
        print(f"Compose:     {svc} networks += auth, {tak_net}")
    elif re.search(r"(?m)^    networks:\s*\[", block):
        def add_inline(b, name):
            m2 = re.search(r"(?m)^    networks:\s*\[([^\]]*)\]", b)
            if not m2:
                return b
            inner = m2.group(1)
            parts = [p.strip() for p in inner.split(",") if p.strip()]
            if name not in parts:
                parts.append(name)
            return b[: m2.start()] + "    networks: [" + ", ".join(parts) + "]" + b[m2.end() :]
        new_block = add_inline(add_inline(block, "auth"), tak_net)
        text = text[: m.end()] + new_block + rest[end_rel:]
        print(f"Compose:     {svc} networks list += auth, {tak_net}")
    else:
        new_block = (
            "\n"
            "    networks:\n"
            "      - auth\n"
            f"      - {tak_net}\n"
            + block
        )
        text = text[: m.end()] + new_block + rest[end_rel:]
        print(f"Compose:     {svc} added networks auth, {tak_net}")

open(compose_file, "w").write(text)
if text == before:
    print(f"Compose:     no content change ({compose_file})")
else:
    print(f"Compose:     wrote {compose_file}")
PY
fi

# Pre-create shared networks (compose marks them external)
for net in auth "${AUTH_NETWORK:-tak}"; do
  if docker network inspect "$net" >/dev/null 2>&1; then
    echo "Network:    $net (exists)"
  elif docker network create "$net" >/dev/null 2>&1; then
    echo "Network:    created $net"
  else
    echo "Network:    could not create $net — create manually before compose up" >&2
  fi
done

umask 077
cat > config/secrets/cloudtak-oidc.txt <<EOF
# Paste into CloudTAK Admin → Login (OIDC). Do not commit.
discovery=https://auth.$domain/.well-known/openid-configuration
client_id=cloudtak
client_secret=$OIDC_CLOUDTAK_CLIENT_SECRET
redirect=(default) https://map.$domain/api/login/oidc/callback
EOF
umask 022

echo
echo "Directory:   $root"
echo "Domain:      $domain"
echo "Auth host:   auth.$domain"
echo "Containers:  auth_lldap auth_authelia [auth_authelia_admin]"
echo "Admin UI:    ADMIN_EXPOSE=$admin_expose"
echo "Env files:   config/common.env config/lldap.env config/authelia.env config/authelia-admin.env"
if [[ -n $compose_file ]]; then
  echo "Compose:     $compose_file  (include auth-home/compose.yaml)"
fi
if [[ $no_swag -eq 1 ]]; then
  echo "Ports:       compose.no-swag.yaml (host publish)"
  echo
  echo "Up by name (preferred on a shared root compose):"
  echo "  docker compose -f compose.yaml -f compose.no-swag.yaml up -d auth_lldap"
  echo "  ./scripts/migrate-users.sh --bind-only"
  echo "  docker compose -f compose.yaml -f compose.no-swag.yaml up -d auth_authelia"
  echo "  docker compose -f compose.yaml -f compose.no-swag.yaml up -d auth_authelia_admin"
  echo "Up by profile (also starts unprofiled services in a shared root compose):"
  echo "  docker compose -f compose.yaml -f compose.no-swag.yaml --profile auth up -d   # still need --bind-only first"
  echo "  docker compose -f compose.yaml -f compose.no-swag.yaml --profile auth --profile admin up -d"
else
  echo "Ports:       none (SWAG proxies on network auth)"
  echo
  echo "Up by name (preferred on a shared root compose):"
  echo "  docker compose up -d auth_lldap"
  echo "  ./scripts/migrate-users.sh --bind-only"
  echo "  docker compose up -d auth_authelia"
  echo "  docker compose up -d auth_authelia_admin"
  echo "Up by profile (also starts unprofiled services in a shared root compose):"
  echo "  docker compose --profile auth up -d   # still need --bind-only before Authelia stays up"
  echo "  docker compose --profile auth --profile admin up -d"
fi
echo "  ./scripts/migrate-users.sh --tak-home /path/to/tak-home [--migrate-plaintext-pass]"
if [[ $no_swag -eq 0 ]]; then
  echo "  Copy swag/auth.conf → SWAG site-confs; nginx -t && reload"
fi
echo "  CloudTAK OIDC: config/secrets/cloudtak-oidc.txt"
