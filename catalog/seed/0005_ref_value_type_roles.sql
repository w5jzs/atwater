-- =====================================================================
-- Atwater seed · 0005 · value-type roles for NASEM and EFSA (design 0002 A1)
--
-- recommended  floor (target_low) and the reference for below_recommended
-- target       amount_low is a floor and amount_high a ceiling, as stored
-- upper_limit  upper_limit, from total-intake values only
-- none         not used for targets
--
-- EFSA has no values loaded yet; its roles are here so its loader only adds
-- data. Roles for the US Dietary Guidelines come with their seed.
-- =====================================================================
BEGIN;

INSERT INTO ref.value_type_role (authority_code, value_type, role, note) VALUES
  ('NASEM_DRI', 'RDA',  'recommended', 'Recommended Dietary Allowance'),
  ('NASEM_DRI', 'AI',   'recommended', 'Adequate Intake'),
  ('NASEM_DRI', 'EAR',  'none',        'Estimated Average Requirement: for assessing groups, not individual targets'),
  ('NASEM_DRI', 'UL',   'upper_limit', 'Tolerable Upper Intake Level'),
  ('NASEM_DRI', 'AMDR', 'target',      'Acceptable Macronutrient Distribution Range'),
  ('NASEM_DRI', 'CDRR', 'target',      'Chronic Disease Risk Reduction Intake (stored as a ceiling)'),
  ('NASEM_DRI', 'DG',   'target',      'Dietary guideline'),
  ('EFSA',      'PRI',  'recommended', 'Population Reference Intake'),
  ('EFSA',      'AI',   'recommended', 'Adequate Intake'),
  ('EFSA',      'AR',   'none',        'Average Requirement: for assessing groups'),
  ('EFSA',      'UL',   'upper_limit', 'Tolerable Upper Intake Level'),
  ('EFSA',      'RI',   'target',      'Reference Intake range for macronutrients');

COMMIT;
