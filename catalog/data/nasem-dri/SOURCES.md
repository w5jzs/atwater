# NASEM Dietary Reference Intakes: raw transcriptions

These CSVs are transcriptions of NASEM's DRI summary tables, laid out as printed: one row per life-stage group, one column per nutrient. They're the input to the DRI seed generator. Don't hand-edit values here without re-checking the source.

## Source

National Academies of Sciences, Engineering, and Medicine. 2019. *Dietary Reference Intakes for Sodium and Potassium*. Appendix J, "Dietary Reference Intakes Summary Tables", the consolidated tables as of 2019. Read 2026-11-22 at https://www.nationalacademies.org/read/25353/chapter/28.

| File | Table (Appendix J, printed page) |
| --- | --- |
| `rda_ai_vitamins.csv` | Recommended Dietary Allowances and Adequate Intakes, Vitamins (pp. 568–569) |
| `rda_ai_elements.csv` | Recommended Dietary Allowances and Adequate Intakes, Elements (pp. 570–571) |
| `rda_ai_macronutrients.csv` | Recommended Dietary Allowances and Adequate Intakes, Total Water and Macronutrients (p. 572) |
| `amdr.csv` | Acceptable Macronutrient Distribution Ranges (p. 573) |
| `ul_vitamins.csv` | Tolerable Upper Intake Levels, Vitamins (pp. 574–575) |
| `ul_elements.csv` | Tolerable Upper Intake Levels, Elements (pp. 576–577) |
| `cdrr_sodium.csv` | Chronic Disease Risk Reduction Intakes (p. 573); pregnancy and lactation rows from the same report's Summary Table S-2, https://www.nationalacademies.org/read/25353/chapter/2 |

## Conventions

- **`*` marks an Adequate Intake (AI).** Unmarked values are RDAs; the printed tables use bold for RDAs, which the text layer loses.
- **`ND`** means not determinable or not determined.
- **Trailing lowercase letters are the table's footnote markers** (`10*h`, `2.4i`, `NDe`). The ones that change meaning are listed below.
- **Units are in the column header**, as printed. Thousands separators are normalized to commas.
- **Column headers drop the footnote letters** and fix OCR artifacts in the source text layer ("Rg/d" for μg/d, ligatures).

## Footnotes that matter for loading

| Table | Note |
| --- | --- |
| RDA/AI vitamins | Vitamin A is retinol activity equivalents (RAE). Vitamin D is cholecalciferol (1 μg = 40 IU). Vitamin E is α-tocopherol. Niacin is niacin equivalents (NE; preformed niacin for 0–6 mo). Folate is dietary folate equivalents (DFE). Choline AIs rest on limited data. |
| RDA/AI vitamins | `i`: adults over 50 should meet the B12 RDA mainly from fortified foods or supplements. `j`, `k`: folic acid advice for women capable of becoming pregnant and during pregnancy. |
| RDA/AI elements, macros | `a` (elements) and `h` (vitamins): infant groups were 0–5.9 and 6–11.9 months. |
| RDA/AI macros | Total water includes water in food, beverages and drinking water. Protein g/d is for the reference body weight (adults 0.8 g/kg). |
| UL vitamins | `a`: vitamin A UL is preformed vitamin A only. `b`, `c`: vitamin E, niacin and folate ULs apply to synthetic forms from supplements, fortified foods or both. Unless noted, a UL covers total intake from food, water and supplements. |
| UL elements | `b`: the magnesium UL is from pharmacological agents only, not food and water. |
| CDRR | Children's and adolescents' values are extrapolated from the adult CDRR based on sedentary EERs (`a`). |

## Corrections made while transcribing

- **Pregnancy 31–50 y, Elements RDA/AI, manganese through chloride.** The page-571 text layer has no values for this row. A first pass filled it by copying the 19–30 y row, which was wrong. The values now come from labelled rows in two other NASEM sources:
  - **Manganese, molybdenum, phosphorus, selenium, zinc:** the NASEM elements summary table PDF (2011, per-element layout), https://www.nationalacademies.org/cdn/materials/9fb9fada-97e1-4f31-a3b4-402a656eee81 (SHA-256 `c8e57f92…be3e273`).
  - **Potassium, sodium:** Summary Tables S-1 and S-2 of the 2019 report.
  - **Chloride:** not found printed with its label, so it's recorded as `UNREADABLE`. Chloride isn't a catalog nutrient, so nothing loads from that cell.

## Verification

- **Shape:** every row has as many fields as its header.
- **Independent second source for elements:** every elements RDA/AI and UL cell that 2019 didn't change (12 elements × 22 life stages × 2 tables = 528 cells) was compared with the 2011 NASEM per-element PDF, which prints each value next to its life-stage label. All 528 agree. Two quirks in that PDF, both on its side: chromium is labelled mg/d (it's μg/d; the numbers match), and 51–70 y is printed as "50−70 y" on several pages.
- **No second source for vitamins and macronutrients.** The seed generator cross-checks them against the values already seeded by hand for adults 31–50, and against internal rules (RDA or AI below the UL, and so on).
