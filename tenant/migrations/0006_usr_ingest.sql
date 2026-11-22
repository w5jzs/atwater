-- =====================================================================
-- Atwater tenant · 0006 · ingestion batches
--
-- Every upload or push (Open mHealth JSON, FHIR bundle, FIT/GPX/TCX file,
-- Gadgetbridge export, BLE session) is recorded once. The raw payload is
-- stored encrypted in object storage; normalized rows point back at their
-- batch, so a batch can be reprocessed (new normalizer version) or
-- withdrawn as a unit. Re-uploading the same bytes from the same source
-- is a no-op via the sha256 uniqueness.
-- =====================================================================
BEGIN;

CREATE TABLE usr.ingest_batch (
  user_id            uuid NOT NULL REFERENCES usr.account ON DELETE CASCADE,
  batch_id           uuid NOT NULL,
  source_id          uuid NOT NULL,
  format             text NOT NULL CHECK (format IN (
                       'omh_json','fhir_bundle','fit','gpx','tcx','gadgetbridge_export','ble_session','csv')),
  received_at        timestamptz NOT NULL DEFAULT now(),
  payload_sha256     bytea  NOT NULL CHECK (length(payload_sha256) = 32),
  payload_bytes      bigint NOT NULL CHECK (payload_bytes >= 0),
  object_key         text,                     -- encrypted raw payload in object storage
  status             text NOT NULL DEFAULT 'received'
                       CHECK (status IN ('received','processing','done','failed','rejected')),
  records_accepted   int NOT NULL DEFAULT 0 CHECK (records_accepted  >= 0),
  records_duplicate  int NOT NULL DEFAULT 0 CHECK (records_duplicate >= 0),
  records_rejected   int NOT NULL DEFAULT 0 CHECK (records_rejected  >= 0),
  normalizer_version text,                     -- which mapping produced the rows; reprocess = replay
  error_summary      text,                     -- never raw payload content
  processed_at       timestamptz,
  created_at         timestamptz NOT NULL DEFAULT now(),
  updated_at         timestamptz NOT NULL DEFAULT now(),
  version            int NOT NULL DEFAULT 1,
  PRIMARY KEY (user_id, batch_id),
  UNIQUE (user_id, source_id, payload_sha256),
  FOREIGN KEY (user_id, source_id) REFERENCES usr.data_source
);
CREATE INDEX ingest_batch_pending ON usr.ingest_batch (received_at) WHERE status IN ('received','processing');

-- Normalized rows remember which batch produced them.
ALTER TABLE usr.observation_sample ADD COLUMN ingest_batch_id uuid;
ALTER TABLE usr.observation_sample
  ADD FOREIGN KEY (user_id, ingest_batch_id) REFERENCES usr.ingest_batch (user_id, batch_id);

ALTER TABLE usr.activity_session ADD COLUMN ingest_batch_id uuid;
ALTER TABLE usr.activity_session
  ADD FOREIGN KEY (user_id, ingest_batch_id) REFERENCES usr.ingest_batch (user_id, batch_id);

ALTER TABLE usr.body_measurement ADD COLUMN ingest_batch_id uuid;
ALTER TABLE usr.body_measurement
  ADD FOREIGN KEY (user_id, ingest_batch_id) REFERENCES usr.ingest_batch (user_id, batch_id);

CREATE TRIGGER touch BEFORE UPDATE ON usr.ingest_batch FOR EACH ROW EXECUTE FUNCTION ops.touch_row();

COMMIT;
