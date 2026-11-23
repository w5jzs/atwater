// fdc-import loads a USDA FoodData Central full download (Foundation,
// SR Legacy or Branded; JSON or the .zip it ships in) into the Atwater catalog.
//
//	CATALOG_DATABASE_URL=postgres://... fdc-import --file FoodData_Central_foundation_food_json_2025-12-18.zip
//
// Behaviour:
//   - Streams the file; memory stays flat regardless of file size.
//   - Writes as catalog_admin (SET ROLE), so the catalog's append-only grants
//     apply even when you connect as a more powerful user.
//   - Idempotent: foods already loaded for this dataset release are skipped,
//     so an interrupted run is resumed by running it again. Resuming is
//     refused if the release was started from a different file (SHA-256).
//   - New releases reuse each food's identity (NDB number) and supersede the
//     previous version; history that points at old versions is untouched.
//   - The release label defaults to the date in the FDC file name; a
//     --release that disagrees with it needs --force-release.
//   - --dry-run parses and maps everything and prints the report, writing nothing.
package main

import (
	"archive/zip"
	"context"
	"crypto/sha256"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
)

func main() {
	if err := run(); err != nil {
		fmt.Fprintln(os.Stderr, "fdc-import:", err)
		os.Exit(1)
	}
}

func run() error {
	file := flag.String("file", "", "FDC full-download JSON file, or the .zip containing it")
	release := flag.String("release", "", "release label; defaults to the date in the FDC file name (e.g. 2025-12-18)")
	forceRelease := flag.Bool("force-release", false, "allow a --release that differs from the date in the file name")
	batch := flag.Int("batch", 250, "foods per transaction")
	limit := flag.Int("limit", 0, "stop after N foods (0 = all); for trial runs")
	dryRun := flag.Bool("dry-run", false, "parse and map only; write nothing")
	noSetRole := flag.Bool("no-set-role", false, "don't SET ROLE catalog_admin (connect as it directly instead)")
	flag.Parse()

	if *file == "" {
		return errors.New("--file is required")
	}
	rel, relSource, err := resolveRelease(*file, *release, *forceRelease)
	if err != nil {
		return err
	}
	if !*dryRun && rel == "" {
		return errors.New("--release is required: the file name has no FDC release date (e.g. --release 2025-12-18)")
	}
	*release = rel
	dbURL := os.Getenv("CATALOG_DATABASE_URL")
	if dbURL == "" {
		return errors.New("CATALOG_DATABASE_URL is not set")
	}

	ctx := context.Background()
	sum, err := fileSHA256(*file)
	if err != nil {
		return err
	}
	src, closeSrc, err := openSource(*file)
	if err != nil {
		return err
	}
	defer closeSrc()
	stream, err := openFoodStream(src)
	if err != nil {
		return err
	}

	conn, err := pgx.Connect(ctx, dbURL)
	if err != nil {
		return fmt.Errorf("connecting to catalog: %w", err)
	}
	defer conn.Close(ctx)
	if !*noSetRole {
		if _, err := conn.Exec(ctx, "SET ROLE catalog_admin"); err != nil {
			return fmt.Errorf("SET ROLE catalog_admin (grant membership, or use --no-set-role): %w", err)
		}
	}
	meta, err := loadCatalogMeta(ctx, conn)
	if err != nil {
		return err
	}

	st := newStats()
	start := time.Now()
	fmt.Printf("dataset %s (%s), file %s, sha256 %x\n", stream.DatasetCode, stream.Root, filepath.Base(*file), sum[:6])
	if *release != "" {
		fmt.Printf("release %s (%s)\n", *release, relSource)
	}

	if *dryRun {
		for {
			f, err := stream.Next()
			if errors.Is(err, io.EOF) {
				break
			}
			if err != nil {
				return fmt.Errorf("after %d foods: %w", st.FoodsRead, err)
			}
			st.FoodsRead++
			if p, skip := meta.planFood(f, stream.DatasetCode, st); skip != "" {
				st.FoodsSkipped[skip]++
			} else {
				st.countPlan(p)
				st.NutrientRows += len(p.Nutrients)
				st.PortionRows += len(p.Portions)
			}
			if *limit > 0 && st.FoodsRead >= *limit {
				break
			}
		}
		report(st, time.Since(start), true)
		return nil
	}

	name := map[string]string{"FDC_FOUNDATION": "USDA FoodData Central — Foundation Foods",
		"FDC_SR_LEGACY": "USDA FoodData Central — SR Legacy",
		"FDC_BRANDED":   "USDA FoodData Central — Branded Foods"}[stream.DatasetCode]
	datasetID, created, err := ensureDataset(ctx, conn, stream.DatasetCode, *release, name)
	if err != nil {
		return fmt.Errorf("dataset row: %w", err)
	}
	if !created {
		// Resume skips foods already present for this release, so it is only
		// safe when the earlier runs read this exact file.
		if err := checkResumeSource(ctx, conn, datasetID, *release, sum); err != nil {
			return err
		}
	}
	fmt.Printf("dataset_id %d (%s)\n", datasetID, map[bool]string{true: "new", false: "existing; resuming"}[created])

	runID, err := startRun(ctx, conn, datasetID, filepath.Base(*file), sum)
	if err != nil {
		return err
	}
	im := &importer{conn: conn, meta: meta, datasetID: datasetID, datasetCode: stream.DatasetCode,
		stats: st, groups: map[string]bool{}}

	fail := func(err error) error {
		_ = finishRun(ctx, conn, runID, "failed", st)
		return err
	}
	pending := make([]*fdcFood, 0, *batch)
	flush := func() error {
		if len(pending) == 0 {
			return nil
		}
		if err := im.importBatch(ctx, pending); err != nil {
			return err
		}
		pending = pending[:0]
		fmt.Printf("  %d foods processed\n", st.FoodsRead)
		return nil
	}
	for {
		f, err := stream.Next()
		if errors.Is(err, io.EOF) {
			break
		}
		if err != nil {
			return fail(fmt.Errorf("parsing after %d foods: %w", st.FoodsRead, err))
		}
		st.FoodsRead++
		pending = append(pending, f)
		if len(pending) >= *batch {
			if err := flush(); err != nil {
				return fail(err)
			}
		}
		if *limit > 0 && st.FoodsRead >= *limit {
			break
		}
	}
	if err := flush(); err != nil {
		return fail(err)
	}
	if err := finishRun(ctx, conn, runID, "done", st); err != nil {
		return err
	}
	report(st, time.Since(start), false)
	return nil
}

// fdcFileDate matches the release date FDC puts in its download names:
// FoodData_Central_foundation_food_json_2025-12-18.zip,
// FoodData_Central_sr_legacy_food_json_2018-04.zip (SR Legacy has no day).
var fdcFileDate = regexp.MustCompile(`(?i)^FoodData_Central_.*_(\d{4}-\d{2}(?:-\d{2})?)\.(?:zip|json)$`)

func releaseFromFilename(path string) (string, bool) {
	m := fdcFileDate.FindStringSubmatch(filepath.Base(path))
	if m == nil {
		return "", false
	}
	return m[1], true
}

// resolveRelease picks the release label. The date in the FDC file name is
// the default, because a label that doesn't match the file creates (or
// resumes) the wrong dataset release, and the append-only catalog can't undo
// that. An explicit --release must agree with it unless --force-release.
// Returns "" when there's no label (file name has no date, none given).
func resolveRelease(file, release string, force bool) (label, source string, err error) {
	fromName, ok := releaseFromFilename(file)
	switch {
	case release == "" && ok:
		return fromName, "from file name", nil
	case release == "":
		return "", "", nil
	case !ok:
		return release, "from --release", nil
	case release == fromName:
		return release, "from --release, matches file name", nil
	case force:
		return release, "from --release, overriding file name date " + fromName + " (--force-release)", nil
	default:
		return "", "", fmt.Errorf("--release %q doesn't match the file name's release date %q; "+
			"omit --release to use %q, or add --force-release if the label is deliberate", release, fromName, fromName)
	}
}

func fileSHA256(path string) ([]byte, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	h := sha256.New()
	if _, err := io.Copy(h, f); err != nil {
		return nil, err
	}
	return h.Sum(nil), nil
}

// openSource returns the JSON stream, unwrapping a .zip with one JSON inside.
func openSource(path string) (io.Reader, func(), error) {
	if !strings.EqualFold(filepath.Ext(path), ".zip") {
		f, err := os.Open(path)
		if err != nil {
			return nil, nil, err
		}
		return f, func() { f.Close() }, nil
	}
	zr, err := zip.OpenReader(path)
	if err != nil {
		return nil, nil, err
	}
	var jsonFiles []*zip.File
	for _, zf := range zr.File {
		if strings.EqualFold(filepath.Ext(zf.Name), ".json") && !strings.HasPrefix(filepath.Base(zf.Name), ".") {
			jsonFiles = append(jsonFiles, zf)
		}
	}
	if len(jsonFiles) != 1 {
		zr.Close()
		return nil, nil, fmt.Errorf("%s: expected exactly one .json inside, found %d", filepath.Base(path), len(jsonFiles))
	}
	rc, err := jsonFiles[0].Open()
	if err != nil {
		zr.Close()
		return nil, nil, err
	}
	return rc, func() { rc.Close(); zr.Close() }, nil
}

func report(st *importStats, took time.Duration, dry bool) {
	mode := "import"
	if dry {
		mode = "dry run (nothing written)"
	}
	fmt.Printf("\n%s finished in %s\n", mode, took.Round(time.Millisecond))
	fmt.Printf("  foods read            %d\n", st.FoodsRead)
	if !dry {
		fmt.Printf("  foods inserted        %d\n", st.FoodsInserted)
		fmt.Printf("  already loaded        %d\n", st.FoodsAlreadyLoaded)
		fmt.Printf("  new food identities   %d\n", st.NewFoodIdentities)
		fmt.Printf("  versions superseded   %d\n", st.VersionsSuperseded)
	}
	fmt.Printf("  nutrient rows         %d (excluding energy)\n", st.NutrientRows)
	fmt.Printf("  portion rows          %d (skipped %d without grams or a label)\n", st.PortionRows, st.SkippedPortions)
	if n := sumValues(st.FoodsSkipped); n > 0 {
		fmt.Printf("  foods skipped         %d: %s\n", n, topN(st.FoodsSkipped, 10))
	}
	fmt.Printf("  foods without energy  %d\n", st.FoodsWithoutEnergy)
	if st.Barcodes+st.BarcodesInvalid > 0 {
		fmt.Printf("  barcodes (GTIN-14)    %d (skipped %d invalid)\n", st.Barcodes, st.BarcodesInvalid)
	}
	if st.FoodsPer100mL > 0 {
		fmt.Printf("  foods per 100 mL      %d (no gram portion: serving is a volume)\n", st.FoodsPer100mL)
	}
	if st.IdentityFallbacks > 0 {
		fmt.Printf("  identity fallbacks    %d (GTIN already used in this release; keyed on fdcId)\n", st.IdentityFallbacks)
	}
	fmt.Printf("  energy methods        %s\n", topN(st.EnergyMethods, 10))
	if len(st.UnitMismatches) > 0 {
		fmt.Printf("  unit mismatches       %s\n", topN(st.UnitMismatches, 10))
	}
	if len(st.UnmappedNutrients) > 0 {
		fmt.Printf("  unmapped nutrients    %d distinct; most common: %s\n", len(st.UnmappedNutrients), topN(st.UnmappedNutrients, 8))
		fmt.Println("                        (add them to ref.nutrient to import them)")
	}
}

func sumValues(m map[string]int) (n int) {
	for _, v := range m {
		n += v
	}
	return n
}

func topN(m map[string]int, n int) string {
	type kv struct {
		k string
		v int
	}
	var all []kv
	for k, v := range m {
		all = append(all, kv{k, v})
	}
	sort.Slice(all, func(i, j int) bool { return all[i].v > all[j].v || (all[i].v == all[j].v && all[i].k < all[j].k) })
	if len(all) > n {
		all = all[:n]
	}
	parts := make([]string, len(all))
	for i, e := range all {
		parts[i] = fmt.Sprintf("%s ×%d", e.k, e.v)
	}
	return strings.Join(parts, ", ")
}
