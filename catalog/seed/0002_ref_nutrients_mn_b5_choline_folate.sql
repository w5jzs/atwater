-- =====================================================================
-- Atwater seed · 0002 · nutrients the FDC dry run showed we were missing
--
-- From the first dry run against the real downloads (Foundation
-- 2026-10-29, SR Legacy 2018-04). These were unmapped and have NASEM DRIs,
-- or are the only folate figure a dataset reports:
--   315 Manganese          Foundation 396/424 foods, SR Legacy 6,492/7,793
--   410 Pantothenic acid   Foundation 89,            SR Legacy 6,376
--   421 Choline, total     Foundation 39,            SR Legacy 4,611
--   417 Folate, total      Foundation 172,           SR Legacy 6,851
--       Foundation publishes no Folate DFE (435), so total folate is its
--       only folate figure. DFE is never derived from it (stored as
--       published, same rule as energy). Total folate has no DRI; the
--       folate RDA is expressed in DFE.
--
-- A new file rather than an edit to 0001: applied seed files are
-- checksum-tracked, and the catalog is append-only.
-- Values: NASEM DRIs, adults 31-50. Verify against the source tables
-- before production use (same caveat as 0001).
-- =====================================================================

INSERT INTO ref.nutrient (nutrient_id, code, name, unit_code, category, infoods_tag, fdc_nutrient_number, sort_order) VALUES
  (211,'pantothenic_acid','Pantothenic acid',             'mg',   'vitamin',       'PANTAC',     '410', 51),
  (212,'choline',         'Choline (total)',              'mg',   'vitamin',       'CHOLN',      '421', 52),
  (213,'folate_total',    'Folate (total)',               'ug',   'vitamin',       'FOL',        '417', 53),
  (309,'manganese',       'Manganese',                    'mg',   'mineral',       'MN',         '315', 69);

INSERT INTO ref.nutrient_reference_value
  (authority_code, edition, life_stage_code, nutrient_id, value_type, basis, amount_low, amount_high, unit_code, applies_to) VALUES
  -- Pantothenic acid AI (no UL established)
  ('NASEM_DRI','consolidated-2019','NASEM_DRI/M/31-50y',211,'AI','per_day',5,NULL,'mg','total_intake'),
  ('NASEM_DRI','consolidated-2019','NASEM_DRI/F/31-50y',211,'AI','per_day',5,NULL,'mg','total_intake'),
  -- Choline AI and UL
  ('NASEM_DRI','consolidated-2019','NASEM_DRI/M/31-50y',212,'AI','per_day',550,NULL,'mg','total_intake'),
  ('NASEM_DRI','consolidated-2019','NASEM_DRI/M/31-50y',212,'UL','per_day',NULL,3500,'mg','total_intake'),
  ('NASEM_DRI','consolidated-2019','NASEM_DRI/F/31-50y',212,'AI','per_day',425,NULL,'mg','total_intake'),
  ('NASEM_DRI','consolidated-2019','NASEM_DRI/F/31-50y',212,'UL','per_day',NULL,3500,'mg','total_intake'),
  -- Manganese AI and UL
  ('NASEM_DRI','consolidated-2019','NASEM_DRI/M/31-50y',309,'AI','per_day',2.3,NULL,'mg','total_intake'),
  ('NASEM_DRI','consolidated-2019','NASEM_DRI/M/31-50y',309,'UL','per_day',NULL,11,'mg','total_intake'),
  ('NASEM_DRI','consolidated-2019','NASEM_DRI/F/31-50y',309,'AI','per_day',1.8,NULL,'mg','total_intake'),
  ('NASEM_DRI','consolidated-2019','NASEM_DRI/F/31-50y',309,'UL','per_day',NULL,11,'mg','total_intake');
