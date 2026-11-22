-- =====================================================================
-- Atwater seed · 0007 · US Dietary Guidelines 2025–2030: open questions settled
--
-- Design 0002 open questions, decided 2026-11-22. A new seed because 0006
-- is applied and checksum-tracked. Source as in 0006:
-- https://realfood.gov/documents/DGA.pdf. Quoted as printed:
--
--   p. 2  "Protein serving goals: 1.2–1.6 grams of protein per kilogram of
--          body weight per day, adjusting as needed based on your
--          individual caloric requirements."
--   p. 3  "In general, saturated fat consumption should not exceed 10% of
--          total daily calories."
--   p. 4  "no amount of added sugars or non-nutritive sweeteners is
--          recommended or considered part of a healthy or nutritious diet"
--   p. 6  "Avoid added sugars during infancy and early childhood."
--   p. 7  (Middle Childhood) "No amount of added sugars is recommended."
--
-- Decisions:
--   1. Saturated fat <= 10% of energy from age 2 (as earlier editions
--      applied it), not only adults: adds ages 2-18, and pregnancy and
--      lactation under 19.
--   2. Protein 1.2-1.6 g/kg/day for adults 19+ in every physiological
--      state. The text gives no ages; it's in the general (adult) guidance.
--      Children keep NASEM's values.
--   3. Added sugars: a ceiling of 0 g/day at every age, so any amount logged
--      shows as over the target.
-- =====================================================================
BEGIN;

INSERT INTO ref.life_stage_group (life_stage_code, authority_code, sex, age_min_months, age_max_months, physiological_state, label) VALUES
  ('US_DGA/C/0-1y',  'US_DGA', 'any',    0,  24,  'none',      'Infants and toddlers, under 2 y'),
  ('US_DGA/C/2-18y', 'US_DGA', 'any',    24, 228, 'none',      'Children and adolescents 2-18 y'),
  ('US_DGA/L/0-18y', 'US_DGA', 'female', 0,  228, 'lactating', 'Lactation, under 19 y');

INSERT INTO ref.nutrient_reference_value
  (authority_code, edition, life_stage_code, nutrient_id, value_type, basis, amount_low, amount_high, unit_code, applies_to, note, source_url)
SELECT 'US_DGA', '2025-2030', ls, n.nutrient_id, 'DG', basis, low, high, unit, 'total_intake', note,
       'https://realfood.gov/documents/DGA.pdf'
  FROM (VALUES
    -- 1. saturated fat from age 2
    ('US_DGA/C/2-18y', 'sat_fat', 'pct_energy', NULL::numeric, 10::numeric, '%', 'p. 3: should not exceed 10% of total daily calories; applied from age 2'),
    ('US_DGA/P/0-18y', 'sat_fat', 'pct_energy', NULL, 10, '%', 'p. 3: should not exceed 10% of total daily calories; applied from age 2'),
    ('US_DGA/L/0-18y', 'sat_fat', 'pct_energy', NULL, 10, '%', 'p. 3: should not exceed 10% of total daily calories; applied from age 2'),
    -- 2. protein for adults
    ('US_DGA/A/19+y',  'protein', 'per_kg_body_weight', 1.2, 1.6, 'g', 'p. 2: 1.2-1.6 g protein per kg body weight per day'),
    ('US_DGA/P/19+y',  'protein', 'per_kg_body_weight', 1.2, 1.6, 'g', 'p. 2: 1.2-1.6 g protein per kg body weight per day'),
    ('US_DGA/L/19+y',  'protein', 'per_kg_body_weight', 1.2, 1.6, 'g', 'p. 2: 1.2-1.6 g protein per kg body weight per day'),
    -- 3. added sugars: none, at every age
    ('US_DGA/C/0-1y',  'added_sugars', 'per_day', NULL, 0, 'g', 'p. 6: avoid added sugars during infancy and early childhood'),
    ('US_DGA/C/2-18y', 'added_sugars', 'per_day', NULL, 0, 'g', 'p. 4, p. 7: no amount of added sugars is recommended'),
    ('US_DGA/A/19+y',  'added_sugars', 'per_day', NULL, 0, 'g', 'p. 4: no amount of added sugars is recommended'),
    ('US_DGA/P/0-18y', 'added_sugars', 'per_day', NULL, 0, 'g', 'p. 4: no amount of added sugars is recommended'),
    ('US_DGA/P/19+y',  'added_sugars', 'per_day', NULL, 0, 'g', 'p. 4: no amount of added sugars is recommended'),
    ('US_DGA/L/0-18y', 'added_sugars', 'per_day', NULL, 0, 'g', 'p. 4: no amount of added sugars is recommended'),
    ('US_DGA/L/19+y',  'added_sugars', 'per_day', NULL, 0, 'g', 'p. 4: no amount of added sugars is recommended')
  ) AS v(ls, code, basis, low, high, unit, note)
  JOIN ref.nutrient n ON n.code = v.code;

DO $$
BEGIN
  IF (SELECT count(*) FROM ref.nutrient_reference_value WHERE authority_code = 'US_DGA') <> 18 THEN
    RAISE EXCEPTION 'US_DGA seed 0007: expected 18 US_DGA values in total (a nutrient code failed to match)';
  END IF;
END $$;

COMMIT;
