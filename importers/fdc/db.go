package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strconv"

	"github.com/jackc/pgx/v5"
)

const foodGroupScheme = "FDC_CATEGORY"

func loadCatalogMeta(ctx context.Context, conn *pgx.Conn) (*catalogMeta, error) {
	m := &catalogMeta{nutrientsByFDC: map[string]nutrientInfo{}, units: map[string]unitInfo{}}
	rows, err := conn.Query(ctx, `SELECT nutrient_id, fdc_nutrient_number, unit_code
	                                FROM ref.nutrient WHERE fdc_nutrient_number IS NOT NULL`)
	if err != nil {
		return nil, fmt.Errorf("reading ref.nutrient (has the catalog been bootstrapped?): %w", err)
	}
	for rows.Next() {
		var n nutrientInfo
		var num string
		if err := rows.Scan(&n.ID, &num, &n.Unit); err != nil {
			return nil, err
		}
		m.nutrientsByFDC[num] = n
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	urows, err := conn.Query(ctx, `SELECT unit_code, dimension, to_base::float8 FROM ref.unit`)
	if err != nil {
		return nil, err
	}
	for urows.Next() {
		var code string
		var u unitInfo
		if err := urows.Scan(&code, &u.Dimension, &u.ToBase); err != nil {
			return nil, err
		}
		m.units[code] = u
	}
	if err := urows.Err(); err != nil {
		return nil, err
	}
	if _, ok := m.nutrientsByFDC[fdcEnergyKcal]; !ok {
		return nil, errors.New("catalog has no nutrient with FDC number 208 (energy); load the catalog seed first")
	}
	return m, nil
}

// ensureDataset returns the dataset id for (code, release), creating it.
// Ids are assigned once and never reused.
func ensureDataset(ctx context.Context, conn *pgx.Conn, code, release, name string) (int16, bool, error) {
	var id int16
	err := conn.QueryRow(ctx, `SELECT dataset_id FROM ref.dataset WHERE code = $1 AND release_label = $2`,
		code, release).Scan(&id)
	if err == nil {
		return id, false, nil
	}
	if !errors.Is(err, pgx.ErrNoRows) {
		return 0, false, err
	}
	err = conn.QueryRow(ctx, `
		INSERT INTO ref.dataset (dataset_id, code, release_label, name, license, share_alike, url)
		SELECT coalesce(max(dataset_id), 0) + 1, $1, $2, $3, 'CC0-1.0', false,
		       'https://fdc.nal.usda.gov/download-datasets'
		  FROM ref.dataset
		RETURNING dataset_id`, code, release, name).Scan(&id)
	return id, true, err
}

// checkResumeSource refuses to resume a dataset release from a different file
// than the one it was started from. Resume skips foods already present for
// the release, so a different download under the same label would silently
// keep the old file's versions, and the append-only catalog can't delete them.
// Every earlier run counts, failed ones included: their batches committed.
func checkResumeSource(ctx context.Context, conn *pgx.Conn, datasetID int16, release string, sum []byte) error {
	var file string
	var other []byte
	err := conn.QueryRow(ctx, `
		SELECT source_file, source_sha256 FROM ref.import_run
		 WHERE dataset_id = $1 AND source_sha256 IS DISTINCT FROM $2
		 ORDER BY started_at LIMIT 1`, datasetID, sum).Scan(&file, &other)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil
	}
	if err != nil {
		return fmt.Errorf("checking earlier runs for this release: %w", err)
	}
	return fmt.Errorf("release %q was already imported from a different file (%s, sha256 %x); "+
		"resuming would keep that file's foods. Use a new --release label for a different download, "+
		"or rerun with the original file to resume", release, file, other[:min(6, len(other))])
}

type importer struct {
	conn        *pgx.Conn
	meta        *catalogMeta
	datasetID   int16
	datasetCode string
	stats       *importStats
	groups      map[string]bool
}

// importBatch writes one batch of foods in a single transaction. Foods whose
// (dataset, fdcId) is already present are skipped, so a failed or repeated
// run can simply be started again.
func (im *importer) importBatch(ctx context.Context, foods []*fdcFood) error {
	tx, err := im.conn.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx) //nolint:errcheck

	for _, f := range foods {
		if err := im.importFood(ctx, tx, f); err != nil {
			return fmt.Errorf("fdcId %d (%q): %w", f.FdcID, f.Description, err)
		}
	}
	return tx.Commit(ctx)
}

func (im *importer) importFood(ctx context.Context, tx pgx.Tx, f *fdcFood) error {
	sourceKey := strconv.Itoa(f.FdcID)

	var exists bool
	if err := tx.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM ref.food_version WHERE dataset_id = $1 AND source_key = $2)`,
		im.datasetID, sourceKey).Scan(&exists); err != nil {
		return err
	}
	if exists {
		im.stats.FoodsAlreadyLoaded++
		return nil
	}

	// Stable food identity across releases.
	key := identityKey(f)
	var foodID string
	err := tx.QueryRow(ctx, `SELECT food_id::text FROM ref.food_identity WHERE source_family = $1 AND identity_key = $2`,
		im.datasetCode, key).Scan(&foodID)
	if errors.Is(err, pgx.ErrNoRows) {
		if err := tx.QueryRow(ctx, `INSERT INTO ref.food (canonical_name) VALUES ($1) RETURNING food_id::text`,
			f.Description).Scan(&foodID); err != nil {
			return err
		}
		if _, err := tx.Exec(ctx, `INSERT INTO ref.food_identity (source_family, identity_key, food_id) VALUES ($1, $2, $3)`,
			im.datasetCode, key, foodID); err != nil {
			return err
		}
		im.stats.NewFoodIdentities++
	} else if err != nil {
		return err
	}

	// Food category -> food group.
	var gScheme, gCode *string
	if code, name, ok := categoryCode(f.FoodCategory); ok {
		if !im.groups[code] {
			if _, err := tx.Exec(ctx, `INSERT INTO ref.food_group (scheme, group_code, name) VALUES ($1, $2, $3)
			                           ON CONFLICT DO NOTHING`, foodGroupScheme, code, name); err != nil {
				return err
			}
			im.groups[code] = true
		}
		s := foodGroupScheme
		gScheme, gCode = &s, &code
	}

	energy := pickEnergy(f)
	im.stats.EnergyMethods[energy.Method]++
	kind := "foundation"
	if im.datasetCode == "FDC_SR_LEGACY" {
		kind = "generic"
	}

	// A version from a newer release of the same dataset may already be
	// current (releases imported out of order); then this one is history.
	var newerCurrent *string
	if err := tx.QueryRow(ctx, `
		SELECT v.food_version_id::text FROM ref.food_version v JOIN ref.dataset d USING (dataset_id)
		 WHERE v.food_id = $1 AND v.is_current AND d.code = $2 AND v.dataset_id > $3
		 ORDER BY v.dataset_id DESC LIMIT 1`, foodID, im.datasetCode, im.datasetID).Scan(&newerCurrent); err != nil &&
		!errors.Is(err, pgx.ErrNoRows) {
		return err
	}

	var versionID string
	if err := tx.QueryRow(ctx, `
		INSERT INTO ref.food_version (food_id, dataset_id, source_key, name, food_kind, nutrient_basis,
		                              energy_method, protein_kcal_per_g, fat_kcal_per_g, carb_kcal_per_g,
		                              group_scheme, group_code, is_current, superseded_by)
		VALUES ($1, $2, $3, $4, $5, 'per_100g', $6, $7, $8, $9, $10, $11, $12, $13)
		RETURNING food_version_id::text`,
		foodID, im.datasetID, sourceKey, f.Description, kind, energy.Method,
		energy.Protein, energy.Fat, energy.Carb, gScheme, gCode,
		newerCurrent == nil, newerCurrent).Scan(&versionID); err != nil {
		return err
	}
	im.stats.FoodsInserted++

	// Older releases of this food are superseded by the new version.
	if newerCurrent == nil {
		tag, err := tx.Exec(ctx, `
			UPDATE ref.food_version v SET is_current = false, superseded_by = $1
			  FROM ref.dataset d
			 WHERE d.dataset_id = v.dataset_id AND d.code = $2
			   AND v.food_id = $3 AND v.is_current AND v.food_version_id <> $1`,
			versionID, im.datasetCode, foodID)
		if err != nil {
			return err
		}
		im.stats.VersionsSuperseded += int(tag.RowsAffected())
	}

	// Nutrient vector.
	rows := [][]any{}
	energyRows := 0
	if energy.Kcal != nil {
		rows = append(rows, []any{versionID, im.meta.nutrientsByFDC[fdcEnergyKcal].ID, round6(*energy.Kcal), nil})
		energyRows = 1
	} else {
		im.stats.FoodsWithoutEnergy++
	}
	for _, n := range im.meta.mapNutrients(f, im.stats) {
		rows = append(rows, []any{versionID, n.NutrientID, n.Amount, n.Derivation})
	}
	if len(rows) > 0 {
		n, err := tx.CopyFrom(ctx, pgx.Identifier{"ref", "food_nutrient"},
			[]string{"food_version_id", "nutrient_id", "amount", "derivation"}, pgx.CopyFromRows(rows))
		if err != nil {
			return err
		}
		// Energy is reported separately (foods without energy), matching the
		// dry run's "nutrient rows (excluding energy)".
		im.stats.NutrientRows += int(n) - energyRows
	}

	// Name as published (primary, en-US).
	if _, err := tx.Exec(ctx, `INSERT INTO ref.food_name (food_version_id, locale, name, is_primary) VALUES ($1, 'en-US', $2, true)`,
		versionID, f.Description); err != nil {
		return err
	}

	// Household portions; the first in FDC's sequence is the default.
	for i, p := range mapPortions(f, im.stats) {
		if _, err := tx.Exec(ctx, `
			INSERT INTO ref.food_portion (food_version_id, label, amount, unit_code, gram_weight, is_default, sort_order)
			VALUES ($1, $2, $3, $4, $5, $6, $7)`,
			versionID, p.Label, p.Amount, p.UnitCode, p.GramWeight, i == 0, i); err != nil {
			return err
		}
		im.stats.PortionRows++
	}
	return nil
}

func startRun(ctx context.Context, conn *pgx.Conn, datasetID int16, file string, sum []byte) (string, error) {
	var id string
	err := conn.QueryRow(ctx, `INSERT INTO ref.import_run (importer, dataset_id, source_file, source_sha256)
	                           VALUES ('fdc', $1, $2, $3) RETURNING run_id::text`, datasetID, file, sum).Scan(&id)
	return id, err
}

func finishRun(ctx context.Context, conn *pgx.Conn, runID, status string, st *importStats) error {
	b, err := json.Marshal(st)
	if err != nil {
		return err
	}
	_, err = conn.Exec(ctx, `UPDATE ref.import_run SET status = $2, finished_at = now(), stats = $3 WHERE run_id = $1`,
		runID, status, b)
	return err
}
