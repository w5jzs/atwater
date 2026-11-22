-- =====================================================================
-- Atwater seed · 0006 · Dietary Guidelines for Americans, 2025–2030
--
-- A supplementary guideline (design 0002 A5): users opt in through
-- usr.account.guideline_codes, and its values fold into their authority's
-- layer. It sets no upper limits.
--
-- Source: HHS and USDA, "Dietary Guidelines for Americans, 2025–2030"
-- (PDF, 10 pages, created 2026-01-06), https://realfood.gov/documents/DGA.pdf
-- (SHA-256 c34f1bec...b6bbca1a472), read 2026-11-22. Quoted as printed:
--
--   p. 3  "In general, saturated fat consumption should not exceed 10% of
--          total daily calories."
--   p. 5  "People who should completely avoid alcohol include pregnant
--          women, ..."
--
-- Loaded from those: saturated fat <= 10% of energy for adults 19+ (the
-- text gives no ages; earlier editions applied it from age 2, see design
-- 0002 open question 1), and alcohol = 0 g/day in pregnancy at any age.
--
-- Not loaded:
--   sodium <2,300 mg (14+) and 1,200 / 1,500 / 1,800 (1-3 / 4-8 / 9-13):
--     identical to the NASEM CDRR already in the catalog
--   protein 1.2-1.6 g/kg/day: a target, open question 2
--   added sugars ("no amount ... is recommended"; at most 10 g per meal):
--     per-meal limits are out of scope, open question 3
--   alcohol otherwise ("Consume less alcohol"): no number
-- =====================================================================
BEGIN;

INSERT INTO ref.authority (authority_code, name, region) VALUES
  ('US_DGA', 'Dietary Guidelines for Americans (HHS, USDA)', 'US');

INSERT INTO ref.authority_edition (authority_code, edition, published_on, is_current) VALUES
  ('US_DGA', '2025-2030', '2026-01-07', true);

INSERT INTO ref.value_type_role (authority_code, value_type, role, note) VALUES
  ('US_DGA', 'DG', 'target', 'Dietary guideline limit or goal, stored as a floor or a ceiling');

-- Adults in every physiological state get the general limits; the
-- pregnancy groups also carry the alcohol limit, at any age.
INSERT INTO ref.life_stage_group (life_stage_code, authority_code, sex, age_min_months, age_max_months, physiological_state, label) VALUES
  ('US_DGA/A/19+y',   'US_DGA', 'any',    228, NULL, 'none',      'Adults 19+ y'),
  ('US_DGA/P/0-18y',  'US_DGA', 'female', 0,   228,  'pregnant',  'Pregnancy, under 19 y'),
  ('US_DGA/P/19+y',   'US_DGA', 'female', 228, NULL, 'pregnant',  'Pregnancy, 19+ y'),
  ('US_DGA/L/19+y',   'US_DGA', 'female', 228, NULL, 'lactating', 'Lactation, 19+ y');

INSERT INTO ref.nutrient_reference_value
  (authority_code, edition, life_stage_code, nutrient_id, value_type, basis, amount_low, amount_high, unit_code, applies_to, note, source_url)
SELECT 'US_DGA', '2025-2030', ls, n.nutrient_id, 'DG', basis, NULL, high, unit, 'total_intake', note,
       'https://realfood.gov/documents/DGA.pdf'
  FROM (VALUES
    ('US_DGA/A/19+y',  'sat_fat', 'pct_energy', 10::numeric, '%', 'p. 3: should not exceed 10% of total daily calories'),
    ('US_DGA/P/19+y',  'sat_fat', 'pct_energy', 10,          '%', 'p. 3: should not exceed 10% of total daily calories'),
    ('US_DGA/L/19+y',  'sat_fat', 'pct_energy', 10,          '%', 'p. 3: should not exceed 10% of total daily calories'),
    ('US_DGA/P/0-18y', 'alcohol', 'per_day',    0,           'g', 'p. 5: pregnant women should completely avoid alcohol'),
    ('US_DGA/P/19+y',  'alcohol', 'per_day',    0,           'g', 'p. 5: pregnant women should completely avoid alcohol')
  ) AS v(ls, code, basis, high, unit, note)
  JOIN ref.nutrient n ON n.code = v.code;

DO $$
BEGIN
  IF (SELECT count(*) FROM ref.nutrient_reference_value WHERE authority_code = 'US_DGA') <> 5 THEN
    RAISE EXCEPTION 'US_DGA seed: expected 5 values (a nutrient code failed to match)';
  END IF;
END $$;

COMMIT;
