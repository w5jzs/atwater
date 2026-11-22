-- =====================================================================
-- Atwater tenant · 0010 · pregnancy due date, opt-in guidelines
--
-- Design 0002:
--   A2  usr.physiological_period.due_date lets the resolver pick a
--       trimester-specific life-stage group. Pregnant periods only.
--   A5  usr.account.guideline_codes lists the supplementary guidelines a
--       user follows on top of their authority (e.g. US_DGA). Empty by
--       default; codes are catalog ref.authority codes, format-checked
--       here and validated by middleware, like authority_code.
--
-- app_rw's UPDATE on usr.account is column-level (0007), so the new column
-- gets its own grant. physiological_period has a table-level grant.
-- =====================================================================
BEGIN;

ALTER TABLE usr.physiological_period
  ADD COLUMN due_date date,
  ADD CONSTRAINT due_date_only_when_pregnant CHECK (due_date IS NULL OR state = 'pregnant');

ALTER TABLE usr.account
  ADD COLUMN guideline_codes text[] NOT NULL DEFAULT '{}'  -- [catalog ref.authority]
    CHECK (array_position(guideline_codes, NULL) IS NULL
           AND array_to_string(guideline_codes, ',') ~ '^([A-Za-z0-9_.:-]{1,64}(,[A-Za-z0-9_.:-]{1,64})*)?$'
           AND cardinality(guideline_codes) <= 8);

GRANT UPDATE (guideline_codes) ON usr.account TO app_rw;

COMMIT;
