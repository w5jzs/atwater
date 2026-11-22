-- =====================================================================
-- Atwater tenant · 0009 · warnings on target resolutions
--
-- Design 0001 (D3, D8): the resolver never blocks or clamps a target. It
-- records why a target is missing or far from recommended values, and the
-- app uses that to explain it and show the doctor's-approval disclaimer.
--
-- Shape: a JSON array of objects, e.g.
--   [{"code": "exceeds_upper_limit", "nutrient": "vit_d"},
--    {"code": "stale_body_mass", "detail": {"age_days": 41}}]
-- Codes are owned by the resolver (Go targets module), not CHECKed here:
-- adding a code shouldn't need an ALTER on every shard. Only the array
-- shape is enforced.
--
-- Warnings are derived from the resolution's inputs, so rows sharing an
-- inputs_hash always share warnings; reuse by hash stays correct.
-- ADD COLUMN with a constant default doesn't rewrite the table.
-- =====================================================================
BEGIN;

ALTER TABLE usr.target_resolution
  ADD COLUMN warnings jsonb NOT NULL DEFAULT '[]'
    CHECK (jsonb_typeof(warnings) = 'array');

COMMIT;
