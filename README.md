# Criminal Case Processing Analysis

An end-to-end analysis of how criminal cases move through a two-tier court system, built in **SAS** with a **Python** reference implementation that reproduces every result.

The dataset is a synthetic 11-table relational extract modeled on a district attorney's case management system: 5,797 cases, 3,000 defendants, 12,168 charges, and 27,709 court events across two court levels.

---

## The question

Where does time go between filing and disposition, and what actually drives delay?

The short answer: **continuances, not case complexity.** Cases with four or more continuances take 2.4x longer to dispose than cases with none, and every continuance in the data occurs at a single event type.

---

## Repository layout

```
├── data/                          11 CSV tables (synthetic)
├── sas/
│   └── case_processing_analysis.sas   Main program — runs top to bottom in SAS Studio
├── python/
│   └── analysis.py                Reference implementation, section-for-section
├── results/
│   └── findings.txt               Generated output from the Python run
└── requirements.txt
```

## Data model

| Table | Rows | Grain |
|---|---:|---|
| `01_Defendants` | 3,000 | one row per person |
| `02_Cases` | 5,797 | one row per case |
| `03_CasePersonInvolvement` | 5,797 | links people to cases |
| `04_Offenses` | 12,168 | one row per charge |
| `05_Events` | 27,709 | one row per court setting |
| `06_Sentences` | 944 | one row per sentenced charge |
| `07_Diversions` | 414 | one row per diversion placement |
| `08_OffenseLookup` | 54 | offense code reference |
| `09_Teams` / `10_Courtrooms` / `11_Staff` | 5 / 10 / 30 | org reference |

Cases flow from **General Sessions** (4,274 cases) to **Criminal Court** (1,523 cases) via bindover.

---

## Running it

### SAS

Written for SAS OnDemand for Academics, which is free for academic use and runs SAS Studio in the browser.

1. Upload the contents of `data/` to a folder named `Case_system_data` in **Files (Home)**.
2. Open `sas/case_processing_analysis.sas` in SAS Studio and run it.

The path resolves through `SYSUSERID`, so no editing is needed. Section 0 verifies the files are reachable and halts with a clear message if they aren't, instead of letting errors cascade.

Two file-level defects are repaired at import:

- The CSVs carry a **UTF-8 byte-order mark**, which corrupts the first column name of every table. `PROC IMPORT` silently produces a mangled variable name and every downstream reference to `CaseID` fails.
- They use **Windows line endings**, which can leave a carriage return on the last text field of each row. A contaminated `CaseStatus` will not match `'Closed'`, and the comparison fails silently rather than erroring.

### Python

```bash
pip install -r requirements.txt
python python/analysis.py
```

Both implementations produce the same numbers. The Python version exists so results can be reconciled independently rather than trusted on one stack.

---

## Findings

### Cycle time splits sharply by court level

| Court level | Cases disposed | Median days | Mean days |
|---|---:|---:|---:|
| General Sessions | 4,249 | 178 | 195.9 |
| Criminal Court | 1,506 | 473 | 483.7 |

Criminal Court takes **2.7x longer** at the median. That gap is structural: bindover cases carry indictment and grand jury steps that General Sessions cases never reach.

### Continuances are the delay driver

40.4% of all 27,709 events are continuances — and every one of them falls on a **Report Date** setting (58.9% of those settings continue). Arraignments, indictments, and grand jury referrals never continue.

| Continuances on case | Cases | Median days |
|---:|---:|---:|
| 0 | 743 | 167 |
| 1 | 1,741 | 193 |
| 2 | 1,535 | 218 |
| 3 | 993 | 221 |
| 4+ | 743 | 395 |

Correlation with cycle time is **0.308** (Pearson), **0.255** (Spearman). The relationship is clearly positive but not linear — the jump appears above three continuances, which argues for treating "4+" as its own operational category rather than modeling continuances as a straight count.

The regression in Section 5e estimates days added per continuance while controlling for court level, charge count, and felony status.

### Disposition mix differs by tier

General Sessions resolves mostly by bindover (32.2% held to state) or dismissal (26.0%). Criminal Court resolves mostly by plea — 31.5% as charged, 22.9% to a lesser charge — with 5.1% going to conviction at trial and 3.0% to acquittal.

Trials are slow and rare: acquittals take a median of 504 days, the longest of any disposition.

### Diversion completion is consistent

| Program | Closed | Successful | Rate |
|---|---:|---:|---:|
| Judicial Diversion | 210 | 172 | 81.9% |
| AG Diversion | 66 | 53 | 80.3% |
| Alternative Court | 96 | 76 | 79.2% |

Revocations cluster on compliance failures (failure to report, failure to comply) rather than new offenses, which account for only 14 of 71.

### Backlog is small but old

Only 42 cases remain pending — but **71.4% have been open more than a year**, and the oldest General Sessions case has been pending 882 days.

### Workload is evenly distributed

Caseloads run 166–228 per Assistant District Attorney across five teams, with median cycle times between 198 and 224 days. No team is an outlier, so the delay pattern is systemic rather than a staffing artifact.

---

## Limitations

This data is **synthetic**, and the analysis is honest about what that means:

- **Charge outcome barely varies by offense category.** Dismissal rates sit between 20.6% and 30.1% across all twelve categories, including homicide and sexual offenses. In real case data these would diverge sharply. The chi-square in Section 6b should be read as a demonstration of method, not a finding.
- **Continuance reasons are near-uniform** (1,526–1,649 occurrences each across seven reasons), which is a signature of random assignment rather than real operational patterns.
- **Filing volume drops off after 2025** for General Sessions, and 83 records carry dates past the as-of date including one case filed in 2027. These are generation artifacts, surfaced rather than silently dropped.

Section 11 of the SAS program runs these checks explicitly. Referential integrity is clean — no orphaned offenses, sentences, or defendants.

The cycle-time and continuance relationships are the results worth taking seriously here, since they were built into the generator as genuine structure. The cross-sectional comparisons were not.

---

## Techniques used

`PROC IMPORT` · `PROC SQL` · `PROC FREQ` · `PROC MEANS` · `PROC UNIVARIATE` · `PROC CORR` · `PROC GLM` · `PROC NPAR1WAY` (Wilcoxon) · `PROC SGPANEL` · SAS macro programming · pandas
