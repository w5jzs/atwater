#!/usr/bin/env bash
# Local/CI entry point: rebuild both databases from scratch through the same
# path staging uses. Point the URLs at a disposable server.
#   CATALOG_DATABASE_URL=postgres://.../atwater_catalog_test \
#   TENANT_DATABASE_URL=postgres://.../atwater_tenant_test ./test/run.sh
set -euo pipefail
: "${CATALOG_DATABASE_URL:?}"; : "${TENANT_DATABASE_URL:?}"
cat_db="$(sed -E 's#^[^/]*//[^/]*/([^?]*).*#\1#' <<<"$CATALOG_DATABASE_URL")"
ten_db="$(sed -E 's#^[^/]*//[^/]*/([^?]*).*#\1#' <<<"$TENANT_DATABASE_URL")"
ATWATER_CONFIRM_RESET="$cat_db,$ten_db" exec "$(dirname "$0")/../bootstrap/bootstrap.sh" --reset
