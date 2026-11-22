-- Shared test helpers: t.expect_error(label, sql, sqlstate) and t.check(label, bool).
SET client_min_messages = warning;
CREATE SCHEMA IF NOT EXISTS t;
CREATE OR REPLACE FUNCTION t.expect_error(label text, stmt text, want text) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  BEGIN
    EXECUTE stmt;
  EXCEPTION WHEN OTHERS THEN
    IF SQLSTATE <> want THEN
      RAISE EXCEPTION 'FAIL %: expected %, got % (%)', label, want, SQLSTATE, SQLERRM;
    END IF;
    RAISE NOTICE 'PASS %', label;
    RETURN;
  END;
  RAISE EXCEPTION 'FAIL %: statement succeeded but should have failed', label;
END $$;
CREATE OR REPLACE FUNCTION t.check(label text, ok boolean) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  IF ok IS NOT TRUE THEN RAISE EXCEPTION 'FAIL %', label; END IF;
  RAISE NOTICE 'PASS %', label;
END $$;
GRANT USAGE ON SCHEMA t TO PUBLIC;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA t TO PUBLIC;
SET client_min_messages = notice;
