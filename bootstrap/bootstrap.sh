#!/usr/bin/env bash
# =====================================================================
# Atwater bootstrap
#
# Brings the catalog and tenant databases to the current schema, in order:
#   1. connectivity   both servers reachable
#   2. databases      both databases exist (optionally create or reset them)
#   3. preflight      version, privileges, extensions, roles, database state
#   4. migrate        apply pending migrations + catalog seed, checksum-tracked
#   5. partitions     ensure tenant partitions around "now" (idempotent)
#   6. smoke tests    run in a transaction and roll back (nothing persists)
#
# Required environment (from your secrets manager; never commit these):
#   CATALOG_DATABASE_URL   postgres://user:pass@host:port/atwater_catalog?sslmode=require
#   TENANT_DATABASE_URL    postgres://user:pass@host:port/atwater_tenant?sslmode=require
# Optional:
#   ATWATER_MAINTENANCE_DB   database used to check/create the targets (default: postgres)
#   ATWATER_MANAGE_ROLES     auto | on | off  (default auto: on if the user has CREATEROLE)
#   ATWATER_CONFIRM_RESET    must equal "<catalog_db>,<tenant_db>" for --reset
#
# Flags:
#   --create-missing   CREATE DATABASE for targets that don't exist (needs CREATEDB)
#   --reset            DROP and recreate both databases (needs ATWATER_CONFIRM_RESET)
#   --preflight-only   stop after preflight; change nothing
#   --skip-tests       don't run smoke tests
# =====================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CREATE_MISSING=0; RESET=0; PREFLIGHT_ONLY=0; SKIP_TESTS=0
for arg in "$@"; do
  case "$arg" in
    --create-missing) CREATE_MISSING=1 ;;
    --reset)          RESET=1; CREATE_MISSING=1 ;;
    --preflight-only) PREFLIGHT_ONLY=1 ;;
    --skip-tests)     SKIP_TESTS=1 ;;
    -h|--help)        sed -n '2,28p' "$0"; exit 0 ;;
    *) echo "unknown flag: $arg" >&2; exit 2 ;;
  esac
done

: "${CATALOG_DATABASE_URL:?CATALOG_DATABASE_URL is required}"
: "${TENANT_DATABASE_URL:?TENANT_DATABASE_URL is required}"
MAINT_DB="${ATWATER_MAINTENANCE_DB:-postgres}"
MANAGE_ROLES="${ATWATER_MANAGE_ROLES:-auto}"

# ---------- output helpers ----------
step() { printf '\n== %s\n' "$*"; }
ok()   { printf '  OK    %s\n' "$*"; }
warn() { printf '  WARN  %s\n' "$*"; }
fail() { printf '  FAIL  %s\n' "$*" >&2; }
die()  { fail "$*"; exit 1; }

# psql against a URL: quiet, stop on error, no ~/.psqlrc
q() { local url="$1"; shift; psql "$url" -X -q -v ON_ERROR_STOP=1 "$@"; }

# ---------- URL handling (passwords never printed) ----------
url_re='^(postgres(ql)?://[^/?]*)(/([^?]*))?(\?.*)?$'
db_of() {
  [[ "$1" =~ $url_re ]] || die "unrecognised database URL (expected postgres://...)"
  printf '%s' "${BASH_REMATCH[4]}"
}
with_db() {   # same server/credentials/options, different database
  [[ "$1" =~ $url_re ]] || die "unrecognised database URL"
  printf '%s/%s%s' "${BASH_REMATCH[1]}" "$2" "${BASH_REMATCH[5]}"
}
redact() { sed -E 's#(://[^:/@]+):[^@]*@#\1:***@#' <<<"$1"; }

CAT_DB="$(db_of "$CATALOG_DATABASE_URL")"
TEN_DB="$(db_of "$TENANT_DATABASE_URL")"
[[ -n "$CAT_DB" && -n "$TEN_DB" ]] || die "both URLs must name a database"
[[ "$CAT_DB" != "$TEN_DB" || "$(with_db "$CATALOG_DATABASE_URL" x)" != "$(with_db "$TENANT_DATABASE_URL" x)" ]] \
  || die "catalog and tenant must be different databases"

# ---------- 1. connectivity ----------
step "connectivity"
for pair in "catalog|$CATALOG_DATABASE_URL" "tenant|$TENANT_DATABASE_URL"; do
  name="${pair%%|*}"; url="${pair#*|}"
  maint="$(with_db "$url" "$MAINT_DB")"
  if v=$(q "$maint" -tAc "SELECT current_setting('server_version')" 2>/tmp/atwater_conn.err); then
    ok "$name server reachable ($(redact "$maint")) — PostgreSQL $v"
  else
    fail "$name server unreachable via maintenance database '$MAINT_DB' ($(redact "$maint"))"
    sed 's/^/        /' /tmp/atwater_conn.err >&2
    die "fix connectivity or set ATWATER_MAINTENANCE_DB"
  fi
done

# ---------- 2. databases ----------
step "databases"
if (( RESET )); then
  [[ "${ATWATER_CONFIRM_RESET:-}" == "$CAT_DB,$TEN_DB" ]] \
    || die "--reset drops data: set ATWATER_CONFIRM_RESET=\"$CAT_DB,$TEN_DB\" to confirm"
fi

db_exists() { [[ "$(q "$(with_db "$1" "$MAINT_DB")" -tAc "SELECT 1 FROM pg_database WHERE datname = '$2'")" == 1 ]]; }
can_createdb() { [[ "$(q "$(with_db "$1" "$MAINT_DB")" -tAc "SELECT rolcreatedb OR rolsuper FROM pg_roles WHERE rolname = current_user")" == t ]]; }

missing=()
for pair in "catalog|$CATALOG_DATABASE_URL|$CAT_DB" "tenant|$TENANT_DATABASE_URL|$TEN_DB"; do
  IFS='|' read -r name url db <<<"$pair"
  maint="$(with_db "$url" "$MAINT_DB")"
  if (( RESET )) && db_exists "$url" "$db"; then
    q "$maint" -c "DROP DATABASE \"$db\" WITH (FORCE)" && warn "$name database '$db' dropped (--reset)"
  fi
  if db_exists "$url" "$db"; then
    ok "$name database '$db' exists"
  elif (( CREATE_MISSING )); then
    can_createdb "$url" || die "$name database '$db' missing and $(q "$maint" -tAc 'select current_user') lacks CREATEDB; create it on the platform"
    q "$maint" -c "CREATE DATABASE \"$db\"" && ok "$name database '$db' created"
  else
    fail "$name database '$db' does not exist"
    missing+=("$db")
  fi
done
if (( ${#missing[@]} )); then
  die "missing database(s): ${missing[*]} — create them on the platform, or rerun with --create-missing"
fi

# ---------- 3. preflight ----------
step "preflight"
if [[ "$MANAGE_ROLES" == auto ]]; then
  MANAGE_ROLES=$(q "$CATALOG_DATABASE_URL" -tAc "SELECT CASE WHEN rolcreaterole OR rolsuper THEN 'on' ELSE 'off' END FROM pg_roles WHERE rolname = current_user")
  ok "manage_roles=auto -> $MANAGE_ROLES"
fi
[[ "$MANAGE_ROLES" == on || "$MANAGE_ROLES" == off ]] || die "ATWATER_MANAGE_ROLES must be auto, on or off"

failed=0
for pair in "catalog|$CATALOG_DATABASE_URL" "tenant|$TENANT_DATABASE_URL"; do
  name="${pair%%|*}"; url="${pair#*|}"
  while IFS='|' read -r level check detail; do
    [[ -z "$level" ]] && continue
    case "$level" in
      OK)   ok   "$name: $check — $detail" ;;
      WARN) warn "$name: $check — $detail" ;;
      *)    fail "$name: $check — $detail"; failed=1 ;;
    esac
  done < <(q "$url" -v component="$name" -v manage_roles="$MANAGE_ROLES" -f "$ROOT/bootstrap/preflight.sql")
done
(( failed )) && die "preflight failed; nothing was changed"
(( PREFLIGHT_ONLY )) && { printf '\npreflight passed; --preflight-only, stopping.\n'; exit 0; }

# ---------- 4. migrate ----------
step "migrate"
ensure_meta() {
  q "$1" -c "CREATE SCHEMA IF NOT EXISTS atwater_meta;
             CREATE TABLE IF NOT EXISTS atwater_meta.applied (
               component  text NOT NULL,
               filename   text NOT NULL,
               sha256     text NOT NULL,
               applied_at timestamptz NOT NULL DEFAULT now(),
               PRIMARY KEY (component, filename));
             REVOKE ALL ON SCHEMA atwater_meta FROM PUBLIC;"
}
apply_tracked() {   # url component file...
  local url="$1" comp="$2"; shift 2
  local f rel sum have
  for f in "$@"; do
    rel="${f#"$ROOT"/}"
    sum="$(sha256sum "$f" | cut -d' ' -f1)"
    have="$(q "$url" -tAc "SELECT sha256 FROM atwater_meta.applied WHERE component = '$comp' AND filename = '$rel'")"
    if [[ -n "$have" ]]; then
      [[ "$have" == "$sum" ]] || die "$rel changed after it was applied to $comp; reset the database (--reset) or write a new migration"
      ok "$comp: $rel (already applied)"
      continue
    fi
    q "$url" -c "SET atwater.manage_roles = '$MANAGE_ROLES'" -f "$f" >/dev/null
    q "$url" -c "INSERT INTO atwater_meta.applied (component, filename, sha256) VALUES ('$comp', '$rel', '$sum')"
    ok "$comp: $rel (applied)"
  done
}
ensure_meta "$CATALOG_DATABASE_URL"
ensure_meta "$TENANT_DATABASE_URL"
apply_tracked "$CATALOG_DATABASE_URL" catalog "$ROOT"/catalog/migrations/*.sql "$ROOT"/catalog/seed/*.sql
apply_tracked "$TENANT_DATABASE_URL"  tenant  "$ROOT"/tenant/migrations/*.sql

# ---------- 5. partitions ----------
step "partitions"
while IFS='|' read -r parent created; do
  [[ -n "$parent" ]] && ok "$parent: $created new"
done < <(q "$TENANT_DATABASE_URL" -tA -F '|' -f "$ROOT/tenant/ops/partitions.sql" | grep '|')

# ---------- 6. smoke tests ----------
if (( SKIP_TESTS )); then
  printf '\nbootstrap complete (tests skipped).\n'; exit 0
fi
step "smoke tests (transactional, rolled back)"
ensure_set_membership() {   # url role...
  local url="$1"; shift; local r
  for r in "$@"; do
    if [[ "$(q "$url" -tAc "SELECT pg_has_role(current_user, '$r', 'SET')")" != t ]]; then
      if [[ "$(q "$url" -tAc "SELECT pg_has_role(current_user, '$r', 'MEMBER WITH ADMIN OPTION') OR (SELECT rolsuper FROM pg_roles WHERE rolname = current_user)")" == t ]]; then
        q "$url" -c "GRANT \"$r\" TO CURRENT_USER WITH INHERIT FALSE, SET TRUE" && ok "granted SET on $r to the bootstrap user (tests only switch into it)"
      else
        die "tests need SET membership in role $r; grant it on the platform or use --skip-tests"
      fi
    fi
  done
}
ensure_set_membership "$CATALOG_DATABASE_URL" catalog_admin catalog_ro
ensure_set_membership "$TENANT_DATABASE_URL"  provisioner app_rw purger

run_suite() {   # url label file
  local out status
  set +e
  out="$(cd "$ROOT/test" && q "$1" -f "$3" 2>&1)"; status=$?
  set -e
  grep -E 'PASS|FAIL|ERROR' <<<"$out" | sed -E 's/^.*NOTICE:  //; s/^/  /'
  grep -q 'SMOKE TESTS PASSED' <<<"$out" && (( status == 0 )) || die "$2 smoke tests failed"
  ok "$2: $(grep -c 'NOTICE:  PASS' <<<"$out") checks passed, changes rolled back"
}
run_suite "$CATALOG_DATABASE_URL" catalog catalog_smoke_test.sql
run_suite "$TENANT_DATABASE_URL"  tenant  tenant_smoke_test.sql

printf '\nbootstrap complete: %s, %s\n' "$CAT_DB" "$TEN_DB"
