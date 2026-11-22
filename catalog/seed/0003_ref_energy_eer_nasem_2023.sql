-- =====================================================================
-- Atwater seed · 0003 · NASEM 2023 Estimated Energy Requirement, adults
--
-- Source: National Academies of Sciences, Engineering, and Medicine.
-- 2023. Dietary Reference Intakes for Energy. Washington, DC: The National
-- Academies Press. Summary, Table S-3 "Summary Table of EER Equations Based
-- on TEE Prediction by Age, Sex, and Physical Activity: Adults"; the same
-- coefficients appear in Table S-1 (TEE prediction equations).
-- https://www.nationalacademies.org/read/26818/chapter/2
--
-- Transcribed from the report (read 2026-11-22), not typed from memory.
-- Table notes, as printed: "For weight stable adults, EER (kcal/d) =
-- TEE (kcal/d). Age is in years, weight is in kilograms, and height is in
-- centimeters." Fit, from the Table S-1 notes: men RMSE 339 kcal/d (MAPE
-- 9.4%), women RMSE 246 kcal/d (MAPE 8.7%). The report doesn't say whether
-- age is whole or fractional years.
--
-- Adults only. The report gives one group per sex, 19 years and above,
-- not the DRI age bands, so these rows hang off new 19+ life-stage groups.
-- Children, pregnancy and lactation are separate equations and not loaded.
--
-- Edition: NASEM publishes DRIs topic by topic, and ref.authority_edition
-- allows one current edition per authority (consolidated-2019 holds it),
-- so this edition is not marked current. The resolver selects energy
-- equations by edition explicitly.
-- =====================================================================

INSERT INTO ref.authority_edition (authority_code, edition, published_on, is_current) VALUES
  ('NASEM_DRI', '2023-energy', NULL, false);

INSERT INTO ref.life_stage_group (life_stage_code, authority_code, sex, age_min_months, age_max_months, label) VALUES
  ('NASEM_DRI/M/19+y', 'NASEM_DRI', 'male',   228, NULL, 'Males 19+ y'),
  ('NASEM_DRI/F/19+y', 'NASEM_DRI', 'female', 228, NULL, 'Females 19+ y');

-- EER = intercept + age_years_coef*age + height_cm_coef*height + weight_kg_coef*weight
-- (the report's "– (10.83 × age)" is a negative age coefficient).
INSERT INTO ref.energy_equation
  (authority_code, edition, life_stage_code, activity_level,
   intercept_kcal, age_years_coef, height_cm_coef, weight_kg_coef, source_url, note) VALUES
  ('NASEM_DRI','2023-energy','NASEM_DRI/M/19+y','inactive',     753.07, -10.83,  6.50, 14.10, 'https://www.nationalacademies.org/read/26818/chapter/2', 'Table S-3; RMSE 339 kcal/d'),
  ('NASEM_DRI','2023-energy','NASEM_DRI/M/19+y','low_active',   581.47, -10.83,  8.30, 14.94, 'https://www.nationalacademies.org/read/26818/chapter/2', 'Table S-3; RMSE 339 kcal/d'),
  ('NASEM_DRI','2023-energy','NASEM_DRI/M/19+y','active',      1004.82, -10.83,  6.52, 15.91, 'https://www.nationalacademies.org/read/26818/chapter/2', 'Table S-3; RMSE 339 kcal/d'),
  ('NASEM_DRI','2023-energy','NASEM_DRI/M/19+y','very_active', -517.88, -10.83, 15.61, 19.11, 'https://www.nationalacademies.org/read/26818/chapter/2', 'Table S-3; RMSE 339 kcal/d'),
  ('NASEM_DRI','2023-energy','NASEM_DRI/F/19+y','inactive',     584.90,  -7.01,  5.72, 11.71, 'https://www.nationalacademies.org/read/26818/chapter/2', 'Table S-3; RMSE 246 kcal/d'),
  ('NASEM_DRI','2023-energy','NASEM_DRI/F/19+y','low_active',   575.77,  -7.01,  6.60, 12.14, 'https://www.nationalacademies.org/read/26818/chapter/2', 'Table S-3; RMSE 246 kcal/d'),
  ('NASEM_DRI','2023-energy','NASEM_DRI/F/19+y','active',       710.25,  -7.01,  6.54, 12.34, 'https://www.nationalacademies.org/read/26818/chapter/2', 'Table S-3; RMSE 246 kcal/d'),
  ('NASEM_DRI','2023-energy','NASEM_DRI/F/19+y','very_active',  511.83,  -7.01,  9.07, 12.56, 'https://www.nationalacademies.org/read/26818/chapter/2', 'Table S-3; RMSE 246 kcal/d');
