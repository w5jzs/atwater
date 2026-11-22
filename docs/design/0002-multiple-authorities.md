# 0002 · More than one authority, and supplementary guidelines

**Status:** Accepted for the groundwork (2026-11-22). The open questions at the end don't block it.
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
| "saturated fat consumption should not exceed 10% of total daily calories" | `sat_fat` ≤ 10% of energy, adults 19+ | Loaded. No ages are given; see open question 1 |
| "People who should completely avoid alcohol include pregnant women" | `alcohol` ≤ 0 g/day, pregnancy | Loaded |
| Sodium < 2,300 mg (14+), < 1,200 / 1,500 / 1,800 (1–3 / 4–8 / 9–13) | — | Not loaded: identical to the NASEM CDRR already in the catalog |
| "1.2–1.6 grams of protein per kilogram of body weight per day" | — | Not loaded yet; see open question 2 |
| "no amount of added sugars … is recommended"; "one meal should contain no more than 10 grams" | — | Not loaded: the only number is per meal, and meal-level targets are out of scope (0001). See open question 3 |
| Alcohol otherwise: "Consume less alcohol" | — | No number |

## Schema changes

| Change | For |
| --- | --- |
| `ref.value_type_role`, seeded for NASEM, EFSA and DGA | A1 |
| `ref.life_stage_group.gestation_stage` | A2 |
| `usr.physiological_period.due_date` | A2 |
| `usr.account.guideline_codes` (with a column grant for `app_rw`) | A5 |

## Open questions

1. **Saturated-fat ages.** The 2025–2030 text gives no ages for the 10% limit; earlier editions applied it from age 2. It's loaded for adults only until you decide whether to extend it to children.
2. **DGA protein (1.2–1.6 g/kg/day).** It's a target range, not a limit, and for users who opt in it would raise the adult floor from NASEM's 0.8 g/kg to 1.2 g/kg (126–168 g for a 105 kg adult). Load it?
3. **Added sugars.** Encode "no amount is recommended" as 0 g/day? That's faithful, but almost any logged food with added sugar would trigger a warning. Or leave it out until meal-level targets exist for the 10 g per-meal limit.
