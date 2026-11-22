-- =====================================================================
-- Atwater tenant · 0008 · physical-activity category on the account
--
-- Input to the energy target (design 0001, D4): the NASEM EER equations
-- take one of four physical-activity categories. It's a person attribute,
-- not a plan attribute, so it lives with the other target-resolution inputs
-- on usr.account. NULL means unknown: the resolver can't compute an EER
-- and records a warning instead of assuming a level.
--
-- app_rw's UPDATE on usr.account is column-level (0007), so the new column
-- needs its own grant or the app can't set it.
-- =====================================================================
BEGIN;

ALTER TABLE usr.account
  ADD COLUMN activity_level text
    CHECK (activity_level IN ('inactive','low_active','active','very_active'));

GRANT UPDATE (activity_level) ON usr.account TO app_rw;

COMMIT;
