-- =====================================================================
-- Atwater tenant · ops · range partitions
--
-- Creates real partitions around "now" for every partitioned usr table.
-- Idempotent: safe to rerun (e.g. from a daily job on staging). Production
-- should hand these tables to pg_partman; this helper exists so a fresh
-- environment works without it and the DEFAULT partitions stay empty.
-- =====================================================================
BEGIN;

CREATE OR REPLACE FUNCTION ops.ensure_range_partitions(
  parent   regclass,
  grain    text,            -- 'day' | 'month' | 'year'
  back     int,             -- periods before the current one
  ahead    int              -- periods after the current one
) RETURNS int
LANGUAGE plpgsql AS $$
DECLARE
  key_type  text;
  step      interval := ('1 ' || grain)::interval;
  fmt       text := CASE grain WHEN 'day' THEN 'YYYYMMDD' WHEN 'month' THEN 'YYYYMM' ELSE 'YYYY' END;
  lo        date := date_trunc(grain, now() AT TIME ZONE 'UTC')::date - (back * step);
  hi        date := date_trunc(grain, now() AT TIME ZONE 'UTC')::date + ((ahead + 1) * step);
  d         date;
  part_name text;
  created   int := 0;
BEGIN
  IF grain NOT IN ('day','month','year') THEN
    RAISE EXCEPTION 'grain must be day, month or year';
  END IF;

  -- Type of the (single-column) partition key decides the bound literals.
  SELECT format_type(a.atttypid, a.atttypmod) INTO key_type
    FROM pg_partitioned_table pt
    JOIN pg_attribute a ON a.attrelid = pt.partrelid AND a.attnum = pt.partattrs[0]
   WHERE pt.partrelid = parent;
  IF key_type IS NULL THEN
    RAISE EXCEPTION '% is not a range-partitioned table', parent;
  END IF;

  d := lo;
  WHILE d < hi LOOP
    part_name := (SELECT relname FROM pg_class WHERE oid = parent) || '_p' || to_char(d, fmt);
    IF to_regclass(format('usr.%I', part_name)) IS NULL THEN
      EXECUTE format(
        'CREATE TABLE usr.%I PARTITION OF %s FOR VALUES FROM (%L) TO (%L)',
        part_name, parent,
        CASE WHEN key_type = 'date' THEN d::text ELSE (d::timestamp AT TIME ZONE 'UTC')::text END,
        CASE WHEN key_type = 'date' THEN (d + step)::date::text
             ELSE ((d + step)::timestamp AT TIME ZONE 'UTC')::text END);
      created := created + 1;
    END IF;
    d := (d + step)::date;
  END LOOP;
  RETURN created;
END $$;

SELECT 'usr.food_log_entry'       AS parent, ops.ensure_range_partitions('usr.food_log_entry',       'month', 2, 3) AS created
UNION ALL SELECT 'usr.hydration_entry',      ops.ensure_range_partitions('usr.hydration_entry',      'month', 2, 3)
UNION ALL SELECT 'usr.activity_session',     ops.ensure_range_partitions('usr.activity_session',     'month', 2, 3)
UNION ALL SELECT 'usr.body_measurement',     ops.ensure_range_partitions('usr.body_measurement',     'month', 2, 3)
UNION ALL SELECT 'usr.change_log',           ops.ensure_range_partitions('usr.change_log',           'month', 1, 2)
UNION ALL SELECT 'usr.observation_sample',   ops.ensure_range_partitions('usr.observation_sample',   'day',   2, 14)
UNION ALL SELECT 'usr.daily_target',         ops.ensure_range_partitions('usr.daily_target',         'year',  1, 1)
UNION ALL SELECT 'usr.daily_nutrient_total', ops.ensure_range_partitions('usr.daily_nutrient_total', 'year',  1, 1)
UNION ALL SELECT 'usr.daily_summary',        ops.ensure_range_partitions('usr.daily_summary',        'year',  1, 1);

COMMIT;
