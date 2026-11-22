-- =====================================================================
-- Atwater tenant · 0005 · bloodwork
--
-- Values, units, ranges and flags are encrypted with the user's DEK and
-- decrypted in middleware (a user has few results, so trends are computed
-- there). The LOINC code stays plaintext so results can be grouped.
-- =====================================================================
BEGIN;

CREATE TABLE usr.lab_report (
  user_id              uuid NOT NULL REFERENCES usr.account ON DELETE CASCADE,
  report_id            uuid NOT NULL,
  collected_at         timestamptz NOT NULL,
  local_date           date NOT NULL,
  reported_at          timestamptz,
  lab_name_enc         bytea,
  document_object_key  text,                 -- encrypted original (PDF/photo) in object storage
  document_sha256      bytea CHECK (document_sha256 IS NULL OR length(document_sha256) = 32),
  entry_method         text NOT NULL CHECK (entry_method IN ('manual','document_assisted','fhir_import')),
  source_id            uuid NOT NULL,
  external_id          text,                 -- FHIR DiagnosticReport id, etc.
  created_at           timestamptz NOT NULL DEFAULT now(),
  updated_at           timestamptz NOT NULL DEFAULT now(),
  version              int NOT NULL DEFAULT 1,
  deleted_at           timestamptz,
  PRIMARY KEY (user_id, report_id),
  FOREIGN KEY (user_id, source_id) REFERENCES usr.data_source
);
CREATE INDEX lab_report_by_date ON usr.lab_report (user_id, collected_at DESC) WHERE deleted_at IS NULL;
CREATE UNIQUE INDEX lab_report_dedupe ON usr.lab_report (user_id, source_id, external_id) WHERE external_id IS NOT NULL;

CREATE TABLE usr.lab_result (
  user_id            uuid NOT NULL,
  result_id          uuid NOT NULL,
  report_id          uuid NOT NULL,
  collected_at       timestamptz NOT NULL,   -- copied from report for range scans
  loinc_code         text CHECK (loinc_code ~ '^[0-9]{1,7}-[0-9]$'),   -- [catalog ref.lab_analyte] NULL until mapped
  payload_enc        bytea NOT NULL,         -- {value, value_text, unit, ref_low, ref_high, ref_text, flag, label_as_printed}
  canonical_enc      bytea,                  -- {value, unit} after UCUM conversion
  confirmed_by_user  boolean NOT NULL DEFAULT false,   -- assisted extraction must be confirmed
  created_at         timestamptz NOT NULL DEFAULT now(),
  updated_at         timestamptz NOT NULL DEFAULT now(),
  version            int NOT NULL DEFAULT 1,
  deleted_at         timestamptz,
  PRIMARY KEY (user_id, result_id),
  FOREIGN KEY (user_id, report_id) REFERENCES usr.lab_report ON DELETE CASCADE
);
CREATE INDEX lab_result_by_report  ON usr.lab_result (user_id, report_id);
CREATE INDEX lab_result_by_analyte ON usr.lab_result (user_id, loinc_code, collected_at DESC) WHERE deleted_at IS NULL;

CREATE TRIGGER touch BEFORE UPDATE ON usr.lab_report FOR EACH ROW EXECUTE FUNCTION ops.touch_row();
CREATE TRIGGER sync  AFTER INSERT OR UPDATE ON usr.lab_report
  FOR EACH ROW EXECUTE FUNCTION ops.record_change('lab_report','report_id');
CREATE TRIGGER touch BEFORE UPDATE ON usr.lab_result FOR EACH ROW EXECUTE FUNCTION ops.touch_row();
CREATE TRIGGER sync  AFTER INSERT OR UPDATE ON usr.lab_result
  FOR EACH ROW EXECUTE FUNCTION ops.record_change('lab_result','result_id');

COMMIT;
