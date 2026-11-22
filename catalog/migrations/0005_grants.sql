-- =====================================================================
-- Atwater catalog · 0005 · privileges
-- Append-only by design: nobody gets DELETE, and the only UPDATEs allowed
-- are lifecycle flags. Ids are never reused, so tenant references stay
-- valid forever.
-- =====================================================================
BEGIN;

REVOKE ALL ON SCHEMA ref FROM PUBLIC;
GRANT USAGE ON SCHEMA ref TO catalog_ro, catalog_admin;

GRANT SELECT ON ALL TABLES IN SCHEMA ref TO catalog_ro, catalog_admin;
GRANT INSERT ON ALL TABLES IN SCHEMA ref TO catalog_admin;
GRANT EXECUTE ON FUNCTION ref.ble_uuid16(text) TO catalog_ro, catalog_admin;

GRANT UPDATE (is_current, superseded_by) ON ref.food_version      TO catalog_admin;
GRANT UPDATE (is_current)                ON ref.authority_edition TO catalog_admin;
GRANT UPDATE (retired_at)                ON ref.diet_plan_version TO catalog_admin;

COMMIT;
