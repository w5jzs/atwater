-- =====================================================================
-- Atwater tenant · 0007 · privileges and row-level security
--
--   app_rw       middleware read/write path. No DELETE anywhere (soft
--                delete only), no INSERT on usr.account, no UPDATE on
--                immutable version tables.
--   app_ro       middleware read path on replicas.
--   provisioner  creates usr.account + the manual data_source from
--                signed user.provisioned events.
--   purger       hard-deletes a user's rows after user.deleted.
--
-- RLS is a second guard behind the repository layer: app roles only see
-- rows where user_id = ops.current_user_id(). Grants and policies target
-- partitioned parents only; partitions are never queried directly.
-- =====================================================================
BEGIN;

REVOKE ALL ON SCHEMA usr, ops FROM PUBLIC;
GRANT USAGE ON SCHEMA usr, ops TO app_rw, app_ro, provisioner, purger;
GRANT EXECUTE ON FUNCTION ops.current_user_id() TO app_rw, app_ro, provisioner, purger;

-- ---------- usr ----------
DO $$
DECLARE t record;
BEGIN
  FOR t IN
    SELECT c.oid::regclass AS rel
      FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE n.nspname = 'usr' AND c.relkind IN ('r','p') AND NOT c.relispartition
  LOOP
    EXECUTE format('GRANT SELECT ON %s TO app_rw, app_ro, provisioner, purger', t.rel);
    EXECUTE format('GRANT INSERT, UPDATE ON %s TO app_rw', t.rel);
    EXECUTE format('GRANT DELETE ON %s TO purger', t.rel);
    EXECUTE format('ALTER TABLE %s ENABLE ROW LEVEL SECURITY', t.rel);
    EXECUTE format($p$CREATE POLICY tenant_isolation ON %s TO app_rw, app_ro
                       USING (user_id = ops.current_user_id())
                       WITH CHECK (user_id = ops.current_user_id())$p$, t.rel);
    EXECUTE format('CREATE POLICY service_access ON %s TO provisioner, purger USING (true) WITH CHECK (true)', t.rel);
  END LOOP;
END $$;

-- Only the auth domain creates users; the app edits profile fields only
-- (never keys, cursor or identity).
REVOKE INSERT, UPDATE ON usr.account FROM app_rw;
GRANT UPDATE (birth_date, reference_sex, height_cm, country, locale, tz,
              authority_code, unit_system, deleted_at) ON usr.account TO app_rw;
GRANT  INSERT ON usr.account, usr.data_source TO provisioner;

-- Immutable version rows: insert-only for the app.
REVOKE UPDATE ON usr.custom_food_version, usr.custom_food_nutrient,
                 usr.recipe_ingredient, usr.custom_plan_version
  FROM app_rw;

-- Change log and cursor are written only by ops.record_change (SECURITY DEFINER).
REVOKE INSERT, UPDATE ON usr.change_log FROM app_rw;

COMMIT;
