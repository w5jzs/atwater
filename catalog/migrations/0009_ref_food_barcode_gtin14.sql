-- =====================================================================
-- Atwater catalog · 0009 · barcodes are stored as GTIN-14
--
-- Sources and scanners spell the same barcode in different lengths: FDC's
-- gtinUpc mixes UPC-A (12), EAN-13, GTIN-14 and UPCs with their leading
-- zeros dropped (9-11 digits). Left-padded with zeros to 14 digits they all
-- compare equal, so ref.food_barcode keeps only that form, and a lookup
-- pads the scanned code the same way.
--
-- The check digit must be valid. A scanner verifies it before reporting a
-- code, so a stored code with a bad check digit could never match a scan.
-- The all-zeros code is a placeholder, not a product.
--
-- The table is empty when this applies (no source has loaded barcodes yet).
-- =====================================================================
BEGIN;

CREATE FUNCTION ref.gtin14_ok(gtin text) RETURNS boolean
LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE
RETURN gtin ~ '^[0-9]{14}$' AND gtin <> '00000000000000'
   AND (10 - (SELECT sum(substr(gtin, i, 1)::int * CASE WHEN i % 2 = 1 THEN 3 ELSE 1 END)
                FROM generate_series(1, 13) AS i) % 10) % 10 = substr(gtin, 14, 1)::int;

COMMENT ON FUNCTION ref.gtin14_ok(text) IS
  'True for a 14-digit GTIN (zero-padded) with a valid check digit, other than all zeros';

ALTER TABLE ref.food_barcode
  ADD CONSTRAINT food_barcode_gtin14 CHECK (ref.gtin14_ok(gtin));

COMMENT ON COLUMN ref.food_barcode.gtin IS
  'GTIN-14: the barcode digits left-padded with zeros to 14, check digit valid. Pad a scanned code the same way to look it up';

GRANT EXECUTE ON FUNCTION ref.gtin14_ok(text) TO catalog_ro, catalog_admin;

COMMIT;
