# 0002 · More than one authority, and supplementary guidelines

**Status:** Accepted (2026-11-22). The DGA questions are settled; see [Resolved questions](#resolved-questions).
**Builds on:** [0001 · Diet-plan rules and target resolution](0001-diet-plan-targets.md)

## Problem

The catalog was designed for many authorities (`ref.authority` already lists EFSA, WHO/FAO, UK SACN and others), but the resolver only works for NASEM. Four things tie it to NASEM:

1. **Value-type meanings are hard-coded.** The resolver knows that RDA and AI are floors and CDRR is a ceiling. EFSA uses PRI, AR and RI, and China uses PI-NCD, which is a ceiling for sodium but a floor for potassium.
2. **Pregnancy is one state.** EFSA, and China, give some values by trimester; EFSA's protein and energy increments are examples. The schema has no trimester.
3. **Activity levels.** Other authorities estimate energy as BMR × PAL, with their own PAL categories.
4. **Nutrient definitions differ.** EFSA's vitamin A is retinol equivalents, not RAE, and the EU's "carbohydrate" is available carbohydrate, not the US by-difference figure. Comparing FDC food data against a target defined differently gives numbers that are quietly wrong.

Separately, the US *Dietary Guidelines for Americans* (DGA) aren't a set of reference values. They're guidance that sits on top of NASEM's DRIs. A user who follows NASEM may also want the DGA's limits.

## Decisions

### A1. Value-type roles are catalog data

New `ref.value_type_role (authority_code, value_type, role)` says what each authority's value types do:

| Role | Meaning in the resolver | NASEM | EFSA |
| --- | --- | --- | --- |
| `recommended` | Floor (`target_low`), and the reference for `below_recommended` | RDA, AI | PRI, AI |
| `target` | `amount_low` is a floor and `amount_high` a ceiling, as stored | AMDR, CDRR, DG | RI |
| `upper_limit` | `upper_limit` (total intake only) | UL | UL |
| `none` | Not used for targets | EAR | AR |

The direction lives in the data, not the role. A `target` row that sets only `amount_high` is a ceiling, and one that sets only `amount_low` is a floor. So China's PI-NCD is just `target`, stored as a high for sodium and a low for potassium; there's no need for per-nutrient roles. A value type with no role for its authority is ignored, with a warning in the resolution.

Within the authority layer the existing rule holds (0001 D2): the highest floor and the lowest ceiling win.

### A2. Trimester-specific life-stage groups

- `ref.life_stage_group.gestation_stage` (`trimester_1`, `trimester_2`, `trimester_3`, or NULL), allowed only on pregnant groups.
- `usr.physiological_period.due_date` (pregnant periods only).

The resolver computes gestational age as 280 days minus the days until the due date, and from that the trimester: under 14 weeks is the first, 14 to under 28 the second, 28 and over the third. For a pregnant user it picks the group for her trimester, falling back to a group with no stage. That fallback is how NASEM works today. With no due date, only groups without a stage can match. If an authority only has trimester groups, the resolver records `no_life_stage_group` with the reason, rather than guessing.

### A3. Activity levels map onto the four we have

`usr.account.activity_level` keeps NASEM's four categories. An authority's energy equations are loaded keyed by those four, converted at load time. EFSA's PAL values of 1.4, 1.6, 1.8 and 2.0 map one-to-one onto inactive, low active, active and very active. Its BMR × PAL form is linear, so it fits `ref.energy_equation` once PAL is multiplied through the coefficients. China's three PAL levels will need an explicit mapping when it's loaded, recorded in its seed. No schema change.

### A4. Nutrient definitions: attach to the matching nutrient, or don't load

An authority's value attaches to the catalog nutrient with the same definition. If there isn't one, the value isn't loaded. The loader skips it with a reason, as the NASEM generator already does for the vitamin A UL. It is never attached to a near-miss nutrient. Equivalences we accept are written down in the authority's `SOURCES.md` (for example, "EFSA α-tocopherol = catalog `vit_e`"). Adding a nutrient so that a skipped value can load is a normal catalog change. No schema change.

### A5. Supplementary guidelines are opt-in layers

A guideline (DGA first) is an authority whose values add to the primary authority's layer, and it's chosen per user:

- New `usr.account.guideline_codes text[]`, empty by default. The app may pre-select a guideline for a region, but it's the user's setting, like the authority.
- The resolver looks up the guideline's own life-stage group and folds its values into the authority layer under A1's roles, so the highest floor and lowest ceiling win across both. Its group and edition are recorded in the resolution's inputs.
- A guideline can't set upper limits. Those stay with the primary authority (0001 D2).

### A6. What the DGA 2025–2030 contributes

Source: *Dietary Guidelines for Americans, 2025–2030*, HHS and USDA, January 2026; https://realfood.gov/documents/DGA.pdf, 10 pages. Its quantitative statements, and what loads:

| Statement | Loads as | Status |
| --- | --- | --- |
| "saturated fat consumption should not exceed 10% of total daily calories" | `sat_fat` ≤ 10% of energy, from age 2 | Loaded (seeds 0006, 0007). The text gives no ages; applied from 2, as earlier editions did |
| "People who should completely avoid alcohol include pregnant women" | `alcohol` ≤ 0 g/day, pregnancy | Loaded |
| Sodium < 2,300 mg (14+), < 1,200 / 1,500 / 1,800 (1–3 / 4–8 / 9–13) | — | Not loaded: identical to the NASEM CDRR already in the catalog |
| "1.2–1.6 grams of protein per kilogram of body weight per day" | `protein` 1.2–1.6 g/kg, adults 19+ | Loaded (seed 0007). It's in the general guidance, so children keep NASEM's values |
| "no amount of added sugars … is recommended"; "Avoid added sugars during infancy and early childhood" | `added_sugars` ≤ 0 g/day, every age | Loaded (seed 0007): any amount logged shows as over the target. The 10 g per-meal limit waits for meal-level targets |
| Alcohol otherwise: "Consume less alcohol" | — | No number |

## Schema changes

| Change | For |
| --- | --- |
| `ref.value_type_role`, seeded for NASEM, EFSA and DGA | A1 |
| `ref.life_stage_group.gestation_stage` | A2 |
| `usr.physiological_period.due_date` | A2 |
| `usr.account.guideline_codes` (with a column grant for `app_rw`) | A5 |

## Resolved questions

Settled 2026-11-22:

| # | Question | Decision |
| --- | --- | --- |
| 1 | Saturated-fat ages | From age 2, as earlier editions applied it |
| 2 | DGA protein 1.2–1.6 g/kg/day | Loaded for adults 19+. For users who opt in, it raises the adult floor from 0.8 to 1.2 g/kg (126–168 g at 105 kg) |
| 3 | Added sugars | Ceiling of 0 g/day at every age, so any amount logged is over the target |

Note on added sugars: FDC Foundation and SR Legacy don't report added sugars at all (nutrient 539: 0 of their 8,217 foods), so foods from those datasets add nothing to the daily added-sugar total. FDC Branded reports it from the label for 139,641 of the 428,581 foods imported on 2026-11-23; the ceiling bites on those, and on custom foods and recipes that carry it. A branded food without the value adds nothing, so a day's total is a floor, not a measurement.
