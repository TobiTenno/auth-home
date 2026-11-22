# auth-home

Separate identity stack: Authelia + LLDAP (+ optional authelia-admin).  
Containers use the `auth_` prefix (like `tak_*`). Not part of `tak-home`.

## Quick start

```sh
./setup.sh example.com -f ../docker-compose.yml
# optional: lock admin UIs
./setup.sh example.com -f ../docker-compose.yml --admin-expose tailscale

# Preferred on a shared root compose: name services (does not start unprofiled siblings)
docker compose up -d auth_lldap
./scripts/migrate-users.sh --bind-only   # create Authelia LDAP bind user
docker compose up -d auth_authelia
docker compose up -d auth_authelia_admin  # optional

# Profile form (fine in a standalone auth-home project; on a shared root compose
# --profile auth also starts every service that has no profile). Still run --bind-only
# after LLDAP is up, or Authelia exits with LDAP Invalid Credentials.
docker compose --profile auth up -d
docker compose --profile auth --profile admin up -d

./scripts/migrate-users.sh --tak-home ../tak-home --email-domain example.com --dry-run
./scripts/migrate-users.sh --tak-home ../tak-home --email-domain example.com --migrate-plaintext-pass
```

`-f` programmatically (same idea as `tak-home`):

1. Copies **runtime** files next to the compose file as `auth-home/` (compose, scripts, setup — not `templates/` or `*.template`)  
2. Renders env / Authelia YAML / SWAG conf from the authoring tree into that deploy dir  
3. `include:`s `auth-home/compose.yaml` in the root compose  
4. Ensures top-level `networks.auth` + `networks.tak` (external)  
5. Attaches the `swag` service (override with `--swag-service`) to **both** networks  

Always run setup from the git/authoring clone with `-f`; do not expect templates inside the deploy copy.

## No SWAG (host ports)

```sh
./setup.sh example.com --no-swag
docker compose -f compose.yaml -f compose.no-swag.yaml up -d auth_lldap
./scripts/migrate-users.sh --bind-only
docker compose -f compose.yaml -f compose.no-swag.yaml up -d auth_authelia
docker compose -f compose.yaml -f compose.no-swag.yaml --profile auth up -d   # still need --bind-only first
```

## Authelia LDAP bind user

Authelia binds to LLDAP as `uid=authelia,…` using `LLDAP_AUTHELIA_PASSWORD`. Compose does **not** create that user. After `auth_lldap` is up:

```sh
./scripts/migrate-users.sh --bind-only
```

Then start `auth_authelia`. Full user migrate also ensures the bind user. Symptom if skipped: LLDAP `Authentication error for user "authelia"` and Authelia `LDAP Result Code 49 "Invalid Credentials"`.

Default host ports: `17170`/`3890` (LLDAP), `9091` (Authelia), `8080` (admin). Override with `AUTH_HOST_PORT_*`.

## Env files

| File | Service |
| --- | --- |
| `config/common.env` | all |
| `config/lldap.env` | `auth_lldap` |
| `config/authelia.env` | `auth_authelia` |
| `config/authelia-admin.env` | `auth_authelia_admin` (`AAD_*`) |
| `config/authelia.secrets.env` | setup re-runs only (YAML secrets) |

Compose uses `env_file:` lists (not a single shared `auth.env`).

## Data (bind mounts)

| Host path | Container |
| --- | --- |
| `data/lldap/` | `auth_lldap` → `/data` |
| `data/authelia/` | `auth_authelia` → `/data` (SQLite + notifier) |

These are local directories under the deploy tree (gitignored), not Docker named volumes — so they stay on the same disk as `auth-home/`.

## Admin exposure

`./setup.sh --admin-expose subnet|localhost|tailscale|public` — IP allow on `/auth-admin/` and `/lldap/` only.

## Names

| Container | Role |
| --- | --- |
| `auth_lldap` | directory |
| `auth_authelia` | login / OIDC |
| `auth_authelia_admin` | optional admin UI |
