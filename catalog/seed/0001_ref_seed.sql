-- =====================================================================
-- Atwater seed · 0001 · starter reference data
-- Enough to exercise the schema end to end. Full catalogs (FDC, Compendium,
-- LOINC, other authorities) are loaded by import jobs, not hand-written SQL.
-- Values below: NASEM DRIs for adults 31-50; verify against the source
-- tables before production use.
-- =====================================================================
BEGIN;

INSERT INTO ref.unit (unit_code, dimension, to_base, display_name) VALUES
  ('g','mass',1,'gram'), ('mg','mass',0.001,'milligram'), ('ug','mass',0.000001,'microgram'),
  ('kg','mass',1000,'kilogram'), ('[lb_av]','mass',453.59237,'pound'), ('[oz_av]','mass',28.349523125,'ounce'),
  ('kcal','energy',1,'kilocalorie'), ('kJ','energy',0.239005736,'kilojoule'),
  ('mL','volume',1,'millilitre'), ('L','volume',1000,'litre'),
  ('[foz_us]','volume',29.5735295625,'US fluid ounce'), ('[cup_us]','volume',236.5882365,'US cup'),
  ('[tbs_us]','volume',14.78676478125,'US tablespoon'), ('[tsp_us]','volume',4.92892159375,'US teaspoon'),
  ('m','length',1,'metre'), ('km','length',1000,'kilometre'), ('cm','length',0.01,'centimetre'),
  ('[in_i]','length',0.0254,'inch'), ('[mi_i]','length',1609.344,'mile'),
  ('s','time',1,'second'), ('min','time',60,'minute'), ('h','time',3600,'hour'),
  ('%','ratio',NULL,'percent'), ('{count}','count',1,'count'),
  ('mg/dL','concentration',NULL,'milligrams per decilitre'), ('g/dL','concentration',NULL,'grams per decilitre'),
  ('ng/mL','concentration',NULL,'nanograms per millilitre'),
  ('mmol/L','substance_concentration',NULL,'millimoles per litre'),
  ('mm[Hg]','pressure',NULL,'millimetres of mercury'), ('/min','rate',NULL,'per minute'),
  ('[IU]','activity',NULL,'international unit'), ('kg/m2','ratio',NULL,'kilograms per square metre'),
  ('Cel','temperature',NULL,'degree Celsius'), ('m/s','velocity',1,'metres per second');

INSERT INTO ref.authority (authority_code, name, region) VALUES
  ('NASEM_DRI','National Academies — Dietary Reference Intakes','US'),
  ('EFSA','European Food Safety Authority — Dietary Reference Values','EU'),
  ('WHO_FAO','WHO/FAO nutrient requirements','INTL'),
  ('UK_SACN','UK Dietary Reference Values (COMA/SACN)','GB'),
  ('JP_MHLW','Dietary Reference Intakes for Japanese','JP'),
  ('NHMRC','Nutrient Reference Values for Australia and New Zealand','AU'),
  ('ICMR_NIN','ICMR-NIN Nutrient Requirements for Indians','IN');

INSERT INTO ref.authority_edition (authority_code, edition, is_current) VALUES
  ('NASEM_DRI','consolidated-2019', true);

-- nutrient_id ranges: 1-99 energy/macros, 100-199 fat detail, 200-299 vitamins, 300-399 minerals, 900+ other
INSERT INTO ref.nutrient (nutrient_id, code, name, unit_code, category, infoods_tag, fdc_nutrient_number, sort_order) VALUES
  (1,  'energy',        'Energy',                         'kcal', 'energy',        'ENERC_KCAL', '208', 1),
  (2,  'protein',       'Protein',                        'g',    'macro',         'PROCNT',     '203', 2),
  (3,  'fat',           'Total fat',                      'g',    'macro',         'FAT',        '204', 3),
  (4,  'carbohydrate',  'Carbohydrate (by difference)',   'g',    'macro',         'CHOCDF',     '205', 4),
  (5,  'fiber',         'Dietary fiber',                  'g',    'carb_fraction', 'FIBTG',      '291', 5),
  (6,  'sugars',        'Total sugars',                   'g',    'carb_fraction', 'SUGAR',      '269', 6),
  (7,  'added_sugars',  'Added sugars',                   'g',    'carb_fraction', NULL,         '539', 7),
  (8,  'water',         'Water',                          'g',    'water',         'WATER',      '255', 8),
  (9,  'alcohol',       'Alcohol (ethyl)',                'g',    'other',         'ALC',        '221', 9),
  (100,'sat_fat',       'Saturated fat',                  'g',    'fatty_acid',    'FASAT',      '606', 20),
  (101,'mufa',          'Monounsaturated fat',            'g',    'fatty_acid',    'FAMS',       '645', 21),
  (102,'pufa',          'Polyunsaturated fat',            'g',    'fatty_acid',    'FAPU',       '646', 22),
  (103,'trans_fat',     'Trans fat',                      'g',    'fatty_acid',    'FATRN',      '605', 23),
  (104,'cholesterol',   'Cholesterol',                    'mg',   'sterol',        'CHOLE',      '601', 24),
  (200,'vit_a_rae',     'Vitamin A (RAE)',                'ug',   'vitamin',       'VITA_RAE',   '320', 40),
  (201,'vit_c',         'Vitamin C',                      'mg',   'vitamin',       'VITC',       '401', 41),
  (202,'vit_d',         'Vitamin D (D2 + D3)',            'ug',   'vitamin',       'VITD',       '328', 42),
  (203,'vit_e',         'Vitamin E (alpha-tocopherol)',   'mg',   'vitamin',       'TOCPHA',     '323', 43),
  (204,'vit_k',         'Vitamin K (phylloquinone)',      'ug',   'vitamin',       'VITK1',      '430', 44),
  (205,'thiamin',       'Thiamin',                        'mg',   'vitamin',       'THIA',       '404', 45),
  (206,'riboflavin',    'Riboflavin',                     'mg',   'vitamin',       'RIBF',       '405', 46),
  (207,'niacin',        'Niacin',                         'mg',   'vitamin',       'NIA',        '406', 47),
  (208,'vit_b6',        'Vitamin B6',                     'mg',   'vitamin',       'VITB6A',     '415', 48),
  (209,'folate_dfe',    'Folate (DFE)',                   'ug',   'vitamin',       'FOLDFE',     '435', 49),
  (210,'vit_b12',       'Vitamin B12',                    'ug',   'vitamin',       'VITB12',     '418', 50),
  (300,'calcium',       'Calcium',                        'mg',   'mineral',       'CA',         '301', 60),
  (301,'iron',          'Iron',                           'mg',   'mineral',       'FE',         '303', 61),
  (302,'magnesium',     'Magnesium',                      'mg',   'mineral',       'MG',         '304', 62),
  (303,'phosphorus',    'Phosphorus',                     'mg',   'mineral',       'P',          '305', 63),
  (304,'potassium',     'Potassium',                      'mg',   'mineral',       'K',          '306', 64),
  (305,'sodium',        'Sodium',                         'mg',   'mineral',       'NA',         '307', 65),
  (306,'zinc',          'Zinc',                           'mg',   'mineral',       'ZN',         '309', 66),
  (307,'copper',        'Copper',                         'mg',   'mineral',       'CU',         '312', 67),
  (308,'selenium',      'Selenium',                       'ug',   'mineral',       'SE',         '317', 68),
  (900,'caffeine',      'Caffeine',                       'mg',   'other',         'CAFFN',      '262', 90);
UPDATE ref.nutrient SET parent_nutrient_id = 6 WHERE nutrient_id = 7;
UPDATE ref.nutrient SET parent_nutrient_id = 3 WHERE nutrient_id IN (100,101,102,103);
UPDATE ref.nutrient SET parent_nutrient_id = 4 WHERE nutrient_id IN (5,6);

INSERT INTO ref.life_stage_group (life_stage_code, authority_code, sex, age_min_months, age_max_months, label) VALUES
  ('NASEM_DRI/M/31-50y','NASEM_DRI','male',  372, 612, 'Males 31-50 y'),
  ('NASEM_DRI/F/31-50y','NASEM_DRI','female',372, 612, 'Females 31-50 y');

INSERT INTO ref.nutrient_reference_value
  (authority_code, edition, life_stage_code, nutrient_id, value_type, basis, amount_low, amount_high, unit_code, applies_to) VALUES
  -- Macronutrient ranges (AMDR, % of energy)
  ('NASEM_DRI','consolidated-2019','NASEM_DRI/M/31-50y', 2,'AMDR','pct_energy',10,35,'%','total_intake'),
  ('NASEM_DRI','consolidated-2019','NASEM_DRI/M/31-50y', 3,'AMDR','pct_energy',20,35,'%','total_intake'),
  ('NASEM_DRI','consolidated-2019','NASEM_DRI/M/31-50y', 4,'AMDR','pct_energy',45,65,'%','total_intake'),
  ('NASEM_DRI','consolidated-2019','NASEM_DRI/F/31-50y', 2,'AMDR','pct_energy',10,35,'%','total_intake'),
  ('NASEM_DRI','consolidated-2019','NASEM_DRI/F/31-50y', 3,'AMDR','pct_energy',20,35,'%','total_intake'),
  ('NASEM_DRI','consolidated-2019','NASEM_DRI/F/31-50y', 4,'AMDR','pct_energy',45,65,'%','total_intake'),
  -- Protein RDA by body weight
  ('NASEM_DRI','consolidated-2019','NASEM_DRI/M/31-50y', 2,'RDA','per_kg_body_weight',0.8,NULL,'g','total_intake'),
  ('NASEM_DRI','consolidated-2019','NASEM_DRI/F/31-50y', 2,'RDA','per_kg_body_weight',0.8,NULL,'g','total_intake'),
  -- Fiber AI
  ('NASEM_DRI','consolidated-2019','NASEM_DRI/M/31-50y', 5,'AI','per_day',38,NULL,'g','total_intake'),
  ('NASEM_DRI','consolidated-2019','NASEM_DRI/F/31-50y', 5,'AI','per_day',25,NULL,'g','total_intake'),
  -- Vitamin C
  ('NASEM_DRI','consolidated-2019','NASEM_DRI/M/31-50y',201,'RDA','per_day',90,NULL,'mg','total_intake'),
  ('NASEM_DRI','consolidated-2019','NASEM_DRI/M/31-50y',201,'UL','per_day',NULL,2000,'mg','total_intake'),
  ('NASEM_DRI','consolidated-2019','NASEM_DRI/F/31-50y',201,'RDA','per_day',75,NULL,'mg','total_intake'),
  ('NASEM_DRI','consolidated-2019','NASEM_DRI/F/31-50y',201,'UL','per_day',NULL,2000,'mg','total_intake'),
  -- Vitamin D
  ('NASEM_DRI','consolidated-2019','NASEM_DRI/M/31-50y',202,'RDA','per_day',15,NULL,'ug','total_intake'),
  ('NASEM_DRI','consolidated-2019','NASEM_DRI/M/31-50y',202,'UL','per_day',NULL,100,'ug','total_intake'),
  ('NASEM_DRI','consolidated-2019','NASEM_DRI/F/31-50y',202,'RDA','per_day',15,NULL,'ug','total_intake'),
  ('NASEM_DRI','consolidated-2019','NASEM_DRI/F/31-50y',202,'UL','per_day',NULL,100,'ug','total_intake'),
  -- Calcium
  ('NASEM_DRI','consolidated-2019','NASEM_DRI/M/31-50y',300,'RDA','per_day',1000,NULL,'mg','total_intake'),
  ('NASEM_DRI','consolidated-2019','NASEM_DRI/M/31-50y',300,'UL','per_day',NULL,2500,'mg','total_intake'),
  ('NASEM_DRI','consolidated-2019','NASEM_DRI/F/31-50y',300,'RDA','per_day',1000,NULL,'mg','total_intake'),
  ('NASEM_DRI','consolidated-2019','NASEM_DRI/F/31-50y',300,'UL','per_day',NULL,2500,'mg','total_intake'),
  -- Iron
  ('NASEM_DRI','consolidated-2019','NASEM_DRI/M/31-50y',301,'RDA','per_day',8,NULL,'mg','total_intake'),
  ('NASEM_DRI','consolidated-2019','NASEM_DRI/M/31-50y',301,'UL','per_day',NULL,45,'mg','total_intake'),
  ('NASEM_DRI','consolidated-2019','NASEM_DRI/F/31-50y',301,'RDA','per_day',18,NULL,'mg','total_intake'),
  ('NASEM_DRI','consolidated-2019','NASEM_DRI/F/31-50y',301,'UL','per_day',NULL,45,'mg','total_intake'),
  -- Magnesium (UL applies to supplements only)
  ('NASEM_DRI','consolidated-2019','NASEM_DRI/M/31-50y',302,'RDA','per_day',420,NULL,'mg','total_intake'),
  ('NASEM_DRI','consolidated-2019','NASEM_DRI/M/31-50y',302,'UL','per_day',NULL,350,'mg','supplements_only'),
  ('NASEM_DRI','consolidated-2019','NASEM_DRI/F/31-50y',302,'RDA','per_day',320,NULL,'mg','total_intake'),
  ('NASEM_DRI','consolidated-2019','NASEM_DRI/F/31-50y',302,'UL','per_day',NULL,350,'mg','supplements_only'),
  -- Potassium AI (2019)
  ('NASEM_DRI','consolidated-2019','NASEM_DRI/M/31-50y',304,'AI','per_day',3400,NULL,'mg','total_intake'),
  ('NASEM_DRI','consolidated-2019','NASEM_DRI/F/31-50y',304,'AI','per_day',2600,NULL,'mg','total_intake'),
  -- Sodium: chronic disease risk reduction intake (2019)
  ('NASEM_DRI','consolidated-2019','NASEM_DRI/M/31-50y',305,'CDRR','per_day',NULL,2300,'mg','total_intake'),
  ('NASEM_DRI','consolidated-2019','NASEM_DRI/F/31-50y',305,'CDRR','per_day',NULL,2300,'mg','total_intake');

INSERT INTO ref.metric (metric_code, name, unit_code, value_kind, loinc_code, min_plausible, max_plausible) VALUES
  ('body_mass',      'Body weight',              'kg',      'instant',      '29463-7', 20, 400),
  ('body_height',    'Body height',              'cm',      'instant',      '8302-2',  30, 272),
  ('bmi',            'Body mass index',          'kg/m2',   'instant',      '39156-5', 8,  100),
  ('body_fat_pct',   'Body fat percentage',      '%',       'instant',      '41982-0', 2,  75),
  ('waist_circ',     'Waist circumference',      'cm',      'instant',      '8280-0',  30, 250),
  ('bp_systolic',    'Systolic blood pressure',  'mm[Hg]',  'instant',      '8480-6',  50, 260),
  ('bp_diastolic',   'Diastolic blood pressure', 'mm[Hg]',  'instant',      '8462-4',  25, 160),
  ('heart_rate',     'Heart rate',               '/min',    'instant',      '8867-4',  20, 250),
  ('resting_hr',     'Resting heart rate',       '/min',    'interval_avg', NULL,      20, 150),
  ('steps',          'Steps',                    '{count}', 'interval_sum', NULL,      0,  100000),
  ('active_energy',  'Active energy',            'kcal',    'interval_sum', NULL,      0,  10000),
  ('sleep_duration', 'Sleep duration',           'min',     'interval_sum', NULL,      0,  1440),
  ('body_temp',      'Body temperature',         'Cel',     'instant',      '8310-5',  30, 45),
  ('spo2',           'Oxygen saturation (pulse oximetry)', '%', 'instant',  '59408-5', 50, 100),
  ('cgm_glucose',    'Glucose (capillary/meter)', 'mg/dL',  'instant',      '41653-7', 10, 800),
  ('cadence',        'Cadence',                  '/min',    'interval_avg', NULL,      0,  300),
  ('speed',          'Speed',                    'm/s',     'interval_avg', NULL,      0,  40);

INSERT INTO ref.lab_analyte (loinc_code, name, category, canonical_unit_code, molar_mass_g_per_mol) VALUES
  ('2345-7',  'Glucose [Mass/volume] in Serum or Plasma',             'metabolic', 'mmol/L', 180.156),
  ('4548-4',  'Hemoglobin A1c/Hemoglobin.total in Blood',             'metabolic', '%',      NULL),
  ('2093-3',  'Cholesterol [Mass/volume] in Serum or Plasma',         'lipid',     'mmol/L', 386.654),
  ('2085-9',  'HDL cholesterol [Mass/volume] in Serum or Plasma',     'lipid',     'mmol/L', 386.654),
  ('13457-7', 'LDL cholesterol (calculated) [Mass/volume] in Serum or Plasma', 'lipid', 'mmol/L', 386.654),
  ('2571-8',  'Triglyceride [Mass/volume] in Serum or Plasma',        'lipid',     'mmol/L', NULL);

INSERT INTO ref.lab_unit_conversion (loinc_code, from_unit_code, to_unit_code, factor) VALUES
  ('2345-7', 'mg/dL','mmol/L', 0.0555),   ('2345-7', 'mmol/L','mg/dL', 18.016),
  ('2093-3', 'mg/dL','mmol/L', 0.02586),  ('2093-3', 'mmol/L','mg/dL', 38.67),
  ('2085-9', 'mg/dL','mmol/L', 0.02586),  ('2085-9', 'mmol/L','mg/dL', 38.67),
  ('13457-7','mg/dL','mmol/L', 0.02586),  ('13457-7','mmol/L','mg/dL', 38.67),
  ('2571-8', 'mg/dL','mmol/L', 0.01129),  ('2571-8', 'mmol/L','mg/dL', 88.57);

INSERT INTO ref.tag (tag_code, kind, name) VALUES
  ('dairy','food_class','Dairy'), ('legume','food_class','Legume'), ('whole_grain','food_class','Whole grain'),
  ('red_meat','food_class','Red meat'), ('processed_meat','food_class','Processed meat'),
  ('ultra_processed','processing','Ultra-processed'), ('gluten','allergen','Contains gluten'),
  ('allergen:peanut','allergen','Peanut'), ('vegan','diet','Vegan'), ('vegetarian','diet','Vegetarian');

-- Open mHealth schema mappings (omh namespace). Verify value paths against
-- the published schema versions; load the ieee namespace (IEEE 1752.1)
-- from the open-source schema repository with the same shape.
INSERT INTO ref.omh_schema_map (namespace, schema_name, metric_code, value_path, unit_path) VALUES
  ('omh','heart-rate',            'heart_rate',     '$.heart_rate.value',              '$.heart_rate.unit'),
  ('omh','body-weight',           'body_mass',      '$.body_weight.value',             '$.body_weight.unit'),
  ('omh','body-height',           'body_height',    '$.body_height.value',             '$.body_height.unit'),
  ('omh','body-mass-index',       'bmi',            '$.body_mass_index.value',         '$.body_mass_index.unit'),
  ('omh','body-fat-percentage',   'body_fat_pct',   '$.body_fat_percentage.value',     '$.body_fat_percentage.unit'),
  ('omh','blood-pressure',        'bp_systolic',    '$.systolic_blood_pressure.value', '$.systolic_blood_pressure.unit'),
  ('omh','blood-pressure',        'bp_diastolic',   '$.diastolic_blood_pressure.value','$.diastolic_blood_pressure.unit'),
  ('omh','step-count',            'steps',          '$.step_count',                    NULL),
  ('omh','sleep-duration',        'sleep_duration', '$.sleep_duration.value',          '$.sleep_duration.unit'),
  ('omh','body-temperature',      'body_temp',      '$.body_temperature.value',        '$.body_temperature.unit'),
  ('omh','oxygen-saturation',     'spo2',           '$.oxygen_saturation.value',       '$.oxygen_saturation.unit');

-- Bluetooth SIG GATT health services (16-bit assigned numbers).
INSERT INTO ref.ble_gatt_map (service_uuid, characteristic_uuid, metric_code, field, service_name, characteristic_name) VALUES
  (ref.ble_uuid16('180D'), ref.ble_uuid16('2A37'), 'heart_rate',   'heart_rate',  'Heart Rate',               'Heart Rate Measurement'),
  (ref.ble_uuid16('181D'), ref.ble_uuid16('2A9D'), 'body_mass',    'weight',      'Weight Scale',             'Weight Measurement'),
  (ref.ble_uuid16('181B'), ref.ble_uuid16('2A9C'), 'body_fat_pct', 'body_fat',    'Body Composition',         'Body Composition Measurement'),
  (ref.ble_uuid16('1810'), ref.ble_uuid16('2A35'), 'bp_systolic',  'systolic',    'Blood Pressure',           'Blood Pressure Measurement'),
  (ref.ble_uuid16('1810'), ref.ble_uuid16('2A35'), 'bp_diastolic', 'diastolic',   'Blood Pressure',           'Blood Pressure Measurement'),
  (ref.ble_uuid16('1810'), ref.ble_uuid16('2A35'), 'heart_rate',   'pulse_rate',  'Blood Pressure',           'Blood Pressure Measurement'),
  (ref.ble_uuid16('1809'), ref.ble_uuid16('2A1C'), 'body_temp',    'temperature', 'Health Thermometer',       'Temperature Measurement'),
  (ref.ble_uuid16('1822'), ref.ble_uuid16('2A5F'), 'spo2',         'spo2',        'Pulse Oximeter',           'PLX Continuous Measurement'),
  (ref.ble_uuid16('1808'), ref.ble_uuid16('2A18'), 'cgm_glucose',  'concentration','Glucose',                 'Glucose Measurement'),
  (ref.ble_uuid16('1814'), ref.ble_uuid16('2A53'), 'speed',        'speed',       'Running Speed and Cadence','RSC Measurement'),
  (ref.ble_uuid16('1814'), ref.ble_uuid16('2A53'), 'cadence',      'cadence',     'Running Speed and Cadence','RSC Measurement');

COMMIT;
