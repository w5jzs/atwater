# 0001 · Diet-plan rules and target resolution

**Status:** Accepted (2026-11-22). The open questions are settled; see [Resolved questions](#resolved-questions).

**Product stance.** Atwater is a tracker, not a medical service. Users can set any target they want. When a target strays far from the authority's recommended values, the app says so and shows a disclaimer that they should get a doctor's approval. The resolver warns; it doesn't block or clamp.
**Schema draft:** [diet-plan-rules.v1.schema.json](diet-plan-rules.v1.schema.json)

## Problem

`usr.daily_target` holds one row per user, local date and nutrient: a target range and an upper limit. Nothing fills it yet. Two things are missing:

1. **The plan `rules` format.** `ref.diet_plan_version.rules` and `usr.custom_plan_version.rules` are `jsonb` columns versioned by `rules_schema_version`, but no schema exists. The catalog comment says CI validates `rules` against that schema before a version is published.
2. **The resolution algorithm.** It has to combine the authority's reference values, the assigned plan, the user's overrides and the user's body into one set of daily targets, and record what it used.

Everything on the nutrition side waits on this. The middleware's main jobs are writing food-log entries, rolling up daily totals and comparing them with targets, and the last of those has nothing to compare against.

## What the schema already decides

The design below has to fit what's in the migrations today. It doesn't reopen these:

| Already decided | Where |
| --- | --- |
| One assigned plan per user per day, catalog or custom, as a `daterange` on local dates | `usr.plan_assignment` (exclusion constraint) |
| A planned deficit or surplus lives on the assignment, -1500 to +1500 kcal | `plan_assignment.energy_adjust_kcal` |
| Precedence: clinician beats user beats plan beats authority | `usr.target_override` (comment) |
| Overrides and reference values share four bases: `per_day`, `pct_energy`, `per_kg_body_weight`, `per_1000_kcal` | `target_override.basis`, `ref.nutrient_reference_value.basis` |
| Targets are materialized per day, so history is judged against the targets in force that day | `usr.daily_target` (comment) |
| Each distinct set of inputs is stored once with its provenance and a hash for reuse | `usr.target_resolution (inputs, inputs_hash)` |
| Plan versions are immutable | `ref.diet_plan_version`, `usr.custom_plan_version` |
| Person inputs: birth date, reference sex, height, authority, physiological periods (pregnant, lactating) | `usr.account`, `usr.physiological_period` |
| Body weight is a `body_measurement` row with metric `body_mass`, canonical unit kg | `usr.body_measurement`, `ref.metric` |

## Overview

```
inputs (per user, per local date)                       output
─────────────────────────────────                       ──────
account: sex, birth date, height, authority, activity ─┐
physiological period on that date                     ├─► life-stage group ─► authority layer
body mass (trend, as of that date)                    │
plan assignment → plan version rules                  ├─► plan layer
target overrides (user, clinician) valid that date    ├─► override layers
                                                      └─► resolve ─► target_resolution (inputs, warnings)
                                                                   └► daily_target rows (canonical units, per day)
```

The resolver is a pure function in the Go `targets` module: `Resolve(inputs) → (targets, warnings)`. It reads nothing itself. The worker gathers the inputs from the tenant shard and the cached catalog, calls it, and writes the results. That keeps the algorithm testable with golden files and keeps every input visible in `target_resolution.inputs`.

## Decisions

### D1. Rules document shape

A plan says three things: how to set energy, which nutrient targets it sets, and whether the authority's values fill in everything else.

```json
{
  "schema_version": 1,
  "inherit_authority": true,
  "energy": { "method": "eer" },
  "body_mass": { "basis": "reference_bmi", "reference_bmi": 25 },
  "nutrients": [
    { "nutrient": "protein",      "basis": "per_kg_body_weight", "low": 1.6, "unit": "g" },
    { "nutrient": "fat",          "basis": "pct_energy",         "low": 25, "high": 35, "unit": "%" },
    { "nutrient": "carbohydrate", "basis": "energy_remainder" },
    { "nutrient": "fiber",        "basis": "per_1000_kcal",      "low": 14, "unit": "g" },
    { "nutrient": "sodium",       "basis": "per_day",            "high": 2300, "unit": "mg" }
  ]
}
```

- **Nutrients are named by `ref.nutrient.code`, not `nutrient_id`.** Codes are unique and never reused (the catalog is append-only), so they're as stable as ids and a plan stays readable. The resolver maps codes to ids from the catalog cache, and CI rejects unknown codes.
- **`energy_remainder` is a fifth basis, for plans only.** Most weight-control plans fix protein and one other macro and give the rest of the energy budget to the third. Exactly one of protein, fat or carbohydrate can use it. Overrides and reference values keep the four existing bases.
- **`inherit_authority`** (default `true`): nutrients the plan doesn't mention take the authority's values. A plan that sets `false` is claiming complete coverage, which only makes sense for a therapeutic plan written by a clinician.
- **Left out of v1:** day-of-week or training-day variants, meal-level targets, and "eat back your exercise". Each one changes the shape of the output (several targets per day, or targets that depend on that day's logged activity). They can come in schema v2 without breaking v1 documents.

The JSON Schema enforces shape. A few rules can't be expressed in JSON Schema and are checked by a semantic validator that runs in CI for catalog plans and in the middleware for custom plans:

- each nutrient appears at most once;
- at most one `energy_remainder`, and only on protein, fat or carbohydrate;
- `energy_remainder` and `pct_energy` targets require an energy target (`energy` must be set);
- `unit` matches the nutrient's canonical unit (or `%` for `pct_energy`);
- for **catalog** plans, no `high` above the authority's UL for any life-stage group the plan applies to (see D3).

### D2. How layers combine

Four layers, lowest to highest: **authority → plan → user override → clinician override.**

- **A higher layer replaces a nutrient's whole range, not one bound.** A plan that sets protein `low: 1.6` g/kg and leaves `high` unset means "no upper target", not "keep the authority's upper target". Merging single bounds across layers produces ranges nobody wrote, like a plan's low paired with an authority's high, and makes "why is my target this?" hard to answer.
- **Which authority value becomes the target:**

  | Reference value | Becomes |
  | --- | --- |
  | RDA, or AI when there's no RDA | `target_low` |
  | AMDR | `target_low` and `target_high` (% of energy, converted to grams) |
  | CDRR, DG | `target_high` |
  | UL, `applies_to = total_intake` | `upper_limit` |
  | UL, `applies_to = supplements_only` | Not used against food totals; kept in the inputs for a future supplements view |
  | EAR | Not used. It's for assessing groups, not setting an individual's target |

- **`upper_limit` always comes from the authority and no layer changes it.** It's a safety ceiling, not a preference. Keeping it separate from `target_high` is why `daily_target` has both columns.

### D3. Targets far from recommended values

A user or clinician can set any target, including above the upper limit (for example high-dose vitamin D) or below the RDA.

- **User and clinician overrides and custom plans are accepted as written.** The resolution records a warning and the app shows it with the doctor's-approval disclaimer:
  - `exceeds_upper_limit`: `target_high` above the authority's `upper_limit`;
  - `below_recommended`: `target_low` below the authority's RDA or AI, or `target_high` below it (a plan that caps a nutrient under the recommended intake);
  - `energy_far_from_estimate`: see D4.
- **Catalog plans are the exception.** They're Atwater's own content, so CI rejects any that exceed an upper limit (D1).
- **Never clamp.** A clamped target hides the conflict, and the user ends up trusting a number they didn't set.
- **Plausibility bounds stay.** `plan_assignment.energy_adjust_kcal` (±1500) and a fixed plan's `kcal` (800–6000) are typo guards, not medical limits. Typing `-15000` is a mistake, not a choice.

### D4. Energy target

Energy has no reference value row, so the plan's `energy.method` decides it:

- **`eer`:** the NASEM 2023 Estimated Energy Requirement equations, using sex, age, height, body mass and a physical-activity category, plus the assignment's `energy_adjust_kcal`. NASEM already supplies the other reference values, so this keeps one source.
- **`fixed`:** the plan states `kcal`, e.g. for clinician-prescribed diets.
- **v2, `adaptive`:** estimate expenditure from logged intake and the weight trend once there are 2–3 weeks of data, falling back to `eer` before that. It's the most accurate method for weight loss. It's committed for v2 and needs its own design. v1 already leaves room: it's one more `method` value.

Three rules apply whichever method is used:

- **The activity category is a person attribute, not a plan attribute.** It needs a new `usr.account.activity_level` column (inactive, low active, active, very active, matching NASEM's categories). Logged activity sessions do **not** add to the target in v1: the category already accounts for usual activity, so adding sessions would count it twice.
- **The equation coefficients are catalog data**, in a new append-only `ref.energy_equation` table keyed by authority, edition and life-stage group. The resolver code implements the formula's shape only. That matches how the ingest mappings work: data, not an app release. *Schema change.*
- **No energy floor.** Under the product stance, the target is whatever the plan and adjustment produce. When it differs from the EER by more than 25% (a tunable default, recorded in the inputs), the resolution records `energy_far_from_estimate` and the app shows the disclaimer. Without an EER (for example a `fixed` plan with no body mass on record), there's nothing to compare against and no warning.

### D5. Body mass used for per-kg targets and EER

- **Use a trend, not the latest reading.** Daily weight swings 1–2 kg with water and food, and per-kg targets would swing with it. Take the mean of `body_mass` readings in the 7 days up to and including the local date.
- **Staleness.** If there's no reading in those 7 days, use the most recent reading up to 90 days old and record a `stale_body_mass` warning. Beyond 90 days, or with no reading at all, per-kg targets and EER don't resolve: those rows are left out and the resolution records why. Guessing a weight is worse than showing no target.
- **Reference weight for people well above a healthy weight.** Per-kg protein on actual weight overshoots badly at high body fat. The plan's `body_mass.basis` can be `measured` (default) or `reference_bmi`, which is the weight at the given BMI (default 25) for the user's height. BMI 25 is a starting rule we can revisit; a named clinical formula would be a new `basis` value, so plans written now keep working. Example: at 180 cm, BMI 25 is 81 kg. For a 105 kg person, 1.6 g/kg is 130 g of protein on reference weight versus 168 g on measured weight. EER always uses measured weight; only per-kg nutrient targets follow `body_mass.basis`.
- **Round the weight used to 0.5 kg** before it goes into the inputs. Without that, nearly every day hashes to a new `target_resolution`. With it, consecutive days share one resolution until the trend actually moves.

### D6. Life-stage group

The group comes from `account.authority_code`, `reference_sex`, age in months on the local date (from `birth_date`), and any `physiological_period` covering that date. The resolver picks the one `ref.life_stage_group` row that matches.

- **No match** (missing birth date or sex, or the catalog doesn't cover that age): the authority layer is empty, plan and override targets still resolve, and the resolution records `no_life_stage_group`. Seed 0004 covers all NASEM groups, from infants through over-70s, plus pregnancy and lactation.
- **Infants and young children** use groups with `sex = 'any'`. Match on sex first, then fall back to `any`.
- **Nutrient targets and the energy equation use different groups.** The NASEM 2023 EER equations come with a single 19+ group per sex (`NASEM_DRI/M/19+y`, `/F/19+y`), which overlaps the DRI age bands. So the resolver makes two lookups for the same date: the DRI group (edition `consolidated-2019`) for nutrient values, and the group containing the user's age that has rows in `ref.energy_equation` for the chosen energy edition (`2023-energy`). Editions are named explicitly, not taken from `is_current`, because NASEM publishes by topic and the catalog allows one current edition per authority.
- **Protein has two RDAs for adults 31–50:** `per_kg_body_weight` (0.8 g/kg, from seed 0001) and `per_day` (56 g or 46 g, at reference body weight, from seed 0004). Other groups only have `per_day`. When both exist and a body mass is available (D5), use per-kg; otherwise use per-day.
- **Birthdays matter.** Crossing a group boundary (for example turning 51) changes the inputs on that date, which produces a new resolution from that day on, with no special handling.

### D7. When targets are computed and what's frozen

- **Materialize ahead:** a worker keeps `daily_target` filled from today through today + 7 days, in the user's time zone.
- **Recompute on change:** plan assignment, override, physiological period, profile (birth date, sex, height, activity level), or a new body-mass reading within the 7-day window. Recomputing means building inputs, hashing them, reusing a matching `target_resolution` if one exists, and replacing the `daily_target` rows for the affected dates.
- **The past is frozen, with a grace period for yesterday.** A day's targets freeze at **local midnight + 4 hours**. Until then, yesterday is still editable: someone changing their plan or adjustment at 00:30 after a late evening can still have it apply to the day they just finished. After 04:00 local, yesterday is frozen like every earlier day, and a week is judged against the targets that were in force during it. Today is always recomputable, so a morning weigh-in updates today's targets. The 4 hours is a tunable default.
- **Backfilled data doesn't rewrite history.** A weight entered for last Tuesday affects future trends, not last Tuesday's targets.
- **Plan assignments and overrides can start no earlier than the oldest unfrozen day:** today, or yesterday during the grace period. The middleware checks this. Anything earlier would conflict with frozen history.

### D8. Provenance and versioning

`target_resolution.inputs` records everything the resolver used, so any target can be explained and reproduced:

- authority and edition, life-stage group;
- plan version id and `rules_schema_version`;
- override ids and versions;
- body mass used (rounded), the readings window and the `body_mass.basis`;
- energy method, activity level and equation edition;
- **resolver version.**

Inputs are serialized as canonical JSON (RFC 8785) before hashing, so the same inputs always produce the same hash.

Two more pieces of provenance:

- **Resolver version is an input.** When the algorithm changes, new resolutions get new hashes and old rows stay as they were. No migration rewrites history.
- **Warnings are stored**, in a new `target_resolution.warnings jsonb` column (`exceeds_upper_limit`, `below_recommended`, `energy_far_from_estimate`, `stale_body_mass`, `no_life_stage_group`, `unresolved_nutrient`), so the app can explain a missing or odd target and know when to show the disclaimer. *Schema change.*

### D9. Conversions to stored units

`daily_target` has no basis column: every row is per day, in the nutrient's canonical unit.

- **`pct_energy` → grams:** uses the general Atwater factors (protein 4, carbohydrate 4, fat 9, alcohol 7 kcal/g) against the day's energy target. That's a convention for targets. It's separate from how a food's own energy was measured, which stays stored as published.
- **`per_1000_kcal`:** multiplied by energy target / 1000.
- **`per_kg_body_weight`:** multiplied by the body mass from D5.
- **`energy_remainder`:** the energy target minus the other two macros, divided by the remainder macro's factor. Bounds invert: the remainder's high comes from the other macros' lows, and its low from their highs.

## Worked example

Illustrative numbers only, not anyone's real data: male, 40, 180 cm, 105 kg measured trend, activity category `low active`, the plan from D1, `energy_adjust_kcal = -500`, authority NASEM.

| Step | Result |
| --- | --- |
| Energy | Suppose EER comes to 2,900 kcal. With -500 kcal, the target is **2,400 kcal** |
| Protein | 1.6 g/kg × 81 kg (BMI 25 at 180 cm) = **130 g** low, no high. That's 520 kcal |
| Fat | 25–35% of 2,400 = 600–840 kcal = **67–93 g** |
| Carbohydrate (remainder) | 2,400 − 520 − (840 down to 600) = 1,040–1,280 kcal = **260–320 g** |
| Fiber | 14 g × 2.4 = **34 g** low |
| Sodium | Plan sets 2,300 mg high (same as the CDRR) |
| Everything else | Inherited from NASEM for males 31–50, e.g. vitamin C 90 mg low with a 2,000 mg upper limit |

This becomes one `target_resolution` row and about 35 `daily_target` rows per day. Days keep reusing that resolution until the trend weight moves by 0.5 kg or another input changes.

## Schema changes this implies

| Change | Why |
| --- | --- |
| `usr.account.activity_level` (text + CHECK) | EER input (D4) |
| `ref.energy_equation` (append-only) | EER coefficients as data (D4) |
| `usr.target_resolution.warnings jsonb` | Explain missing or odd targets (D8) |
| Full NASEM DRI tables in the catalog | Only adults 31–50 are seeded today (D6) |
| JSON Schema v1 published where CI can find it | D1 |

None of these touch existing data, and each is a new migration rather than an edit.

## Resolved questions

Settled 2026-11-22:

| # | Question | Decision |
| --- | --- | --- |
| 1 | Upper limits on user overrides | Accept anything; warn and show the doctor's-approval disclaimer. Atwater is a tracker, not a medical service (D3) |
| 2 | Energy floor | None, for the same reason. Warn when energy is more than 25% from the EER (D4) |
| 3 | Backdated plan assignments | Keep the freeze, with a grace period: yesterday stays editable until 04:00 local (D7) |
| 4 | Body-mass window | 7-day mean, readings up to 90 days old with a warning (D5) |
| 5 | Adaptive energy | Committed for v2 (D4) |
| 6 | Adjusted body weight | BMI 25 for now; revisit later (D5) |

Two defaults came out of these and are tunable, not fixed: the 25% energy warning threshold and the 4-hour grace period.

## Not in scope

Training-day or weekday variants, meal-level targets, eating back exercise, adaptive expenditure, children and adolescents beyond what the life-stage groups give, supplement tracking against supplements-only upper limits, and any UI.
