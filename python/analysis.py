"""
Case processing analysis - Python reference implementation.

This mirrors sas/case_processing_analysis.sas section for section so the two
can be reconciled against each other. Run it from the repository root:

    python python/analysis.py

Output is written to stdout and to results/findings.txt.
"""

import sys
from pathlib import Path

import numpy as np
import pandas as pd

ROOT = Path(__file__).resolve().parents[1]
DATA = ROOT / "data"
ASOF = pd.Timestamp("2026-08-13")

pd.set_option("display.width", 200)
pd.set_option("display.max_columns", 40)


def load(name: str) -> pd.DataFrame:
    """Read a table. utf-8-sig strips the byte-order mark the files carry."""
    return pd.read_csv(DATA / name, encoding="utf-8-sig")


def main() -> None:
    defendants = load("01_Defendants.csv")
    cases_raw = load("02_Cases.csv")
    offenses = load("04_Offenses.csv")
    events = load("05_Events.csv")
    sentences = load("06_Sentences.csv")
    diversions = load("07_Diversions.csv")
    teams = load("09_Teams.csv")
    staff = load("11_Staff.csv")

    for col in ("FilingDate", "DispositionDate"):
        cases_raw[col] = pd.to_datetime(cases_raw[col], errors="coerce")

    # ---- Section 2: case-level analysis table -----------------------------
    per_case_events = events.groupby("CaseID").agg(
        EventCount=("EventID", "size"),
        Continuances=("ContinuanceFlag", "sum"),
    )
    per_case_charges = offenses.assign(
        _violent=lambda d: d.OffenseCategory.eq("Violent"),
        _felony=lambda d: d.OffenseClass.str.contains("Felony", na=False),
    ).groupby("CaseID").agg(
        ChargeCount=("OffenseID", "size"),
        ViolentCharges=("_violent", "sum"),
        FelonyCharges=("_felony", "sum"),
    )

    cases = cases_raw.join(per_case_events, on="CaseID").join(
        per_case_charges, on="CaseID"
    )
    for col in ("EventCount", "Continuances", "ChargeCount", "FelonyCharges"):
        cases[col] = cases[col].fillna(0)

    cases["DaysToDisp"] = (cases.DispositionDate - cases.FilingDate).dt.days
    cases["PendingAge"] = np.where(
        cases.DispositionDate.isna(), (ASOF - cases.FilingDate).dt.days, np.nan
    )
    cases["FilingYear"] = cases.FilingDate.dt.year
    cases["HasFelony"] = (cases.FelonyCharges > 0).astype(int)
    cases["ContBand"] = pd.cut(
        cases.Continuances, [-1, 0, 1, 2, 3, 999], labels=["0", "1", "2", "3", "4+"]
    )

    out = []

    def show(title, obj):
        out.append(f"\n### {title}\n{obj}")
        print(f"\n### {title}")
        print(obj)

    # ---- Section 3: inventory and disposition -----------------------------
    show("3a. Inventory by court level and status",
         pd.crosstab(cases.CourtLevel, cases.CaseStatus, margins=True))

    closed = cases[cases.CaseDisposition.notna()]
    disp = pd.crosstab(closed.CourtLevel, closed.CaseDisposition)
    show("3b. Disposition counts", disp)
    show("3b. Disposition row percent",
         (disp.div(disp.sum(axis=1), axis=0) * 100).round(1))

    # ---- Section 4: time to disposition -----------------------------------
    show("4a. Days to disposition by court level",
         cases.groupby("CourtLevel").DaysToDisp.describe()
              [["count", "mean", "50%", "75%", "max"]].round(1))
    show("4b. Days to disposition by disposition type",
         cases.groupby("CaseDisposition").DaysToDisp
              .agg(["count", "mean", "median"]).round(1)
              .sort_values("median"))

    # ---- Section 5: continuances ------------------------------------------
    show("5a. Continuance rate overall",
         f"{events.ContinuanceFlag.mean() * 100:.1f}% of {len(events):,} events")
    by_type = events.groupby("EventType").ContinuanceFlag.agg(["count", "sum", "mean"])
    by_type["mean"] = (by_type["mean"] * 100).round(1)
    show("5a. Continuance rate by event type", by_type.sort_values("count", ascending=False))
    show("5b. Continuance reasons",
         events.loc[events.ContinuanceFlag == 1, "ContinuanceReason"]
               .value_counts().head(10))

    disposed = cases[cases.DaysToDisp.notna()]
    show("5c. Cycle time by continuance count",
         disposed.groupby("ContBand", observed=True).DaysToDisp
                 .agg(["count", "median", "mean"]).round(1))
    show("5d. Correlation of continuances with cycle time",
         f"Pearson {disposed.Continuances.corr(disposed.DaysToDisp):.3f}   "
         f"Spearman {disposed.Continuances.corr(disposed.DaysToDisp, method='spearman'):.3f}")

    # ---- Section 6: offenses ----------------------------------------------
    show("6a. Charge volume by category", offenses.OffenseCategory.value_counts())
    show("6a. Charge volume by class", offenses.OffenseClass.value_counts())
    show("6b. Charge outcome by category (row percent)",
         (pd.crosstab(offenses.OffenseCategory, offenses.ChargeDisposition,
                      normalize="index") * 100).round(1))

    # ---- Section 7: diversions --------------------------------------------
    show("7a. Diversion outcome by type",
         pd.crosstab(diversions.DiversionType, diversions.DiversionStatus))
    closed_div = diversions[diversions.DiversionStatus != "Active"]
    rate = closed_div.groupby("DiversionType").DiversionStatus.agg(
        Closed="size", Successful=lambda s: (s == "Successful").sum()
    )
    rate["SuccessPct"] = (rate.Successful / rate.Closed * 100).round(1)
    show("7b. Completion rate on closed diversions", rate.sort_values("SuccessPct", ascending=False))
    show("7c. Revocation reasons",
         diversions.loc[diversions.DiversionStatus == "Revoked", "RevocationReason"]
                   .value_counts())

    # ---- Section 8: sentences ---------------------------------------------
    sent = sentences.merge(
        offenses[["OffenseID", "OffenseCategory", "OffenseClass"]],
        on="OffenseID", how="left",
    )
    show("8a. Sentence length by sentence type",
         sent.groupby("SentenceType")[
             ["TotalSentenceMonths", "IncarcerationMonths", "ProbationMonths"]
         ].agg(["count", "mean", "median"]).round(1))
    show("8b. Sentence length by offense class",
         sent.groupby("OffenseClass").TotalSentenceMonths
             .agg(["count", "median"]).sort_values("median", ascending=False))

    # ---- Section 9: workload ----------------------------------------------
    team_load = cases.groupby("TeamID").agg(
        Cases=("CaseID", "size"),
        MedianDays=("DaysToDisp", "median"),
        AvgContinuances=("Continuances", "mean"),
    ).round(2).join(teams.set_index("TeamID").TeamName)
    show("9a. Caseload and cycle time by team", team_load)

    staff_load = (
        cases.groupby("AssignedStaffID").size().rename("Cases").reset_index()
        .merge(staff, left_on="AssignedStaffID", right_on="StaffID", how="left")
    )
    show("9b. Caseload per assigned staff",
         staff_load.groupby("StaffRole").Cases.agg(["count", "sum", "mean", "min", "max"]).round(1))

    # ---- Section 10: filing trend and backlog -----------------------------
    show("10a. Filings by year and court level",
         pd.crosstab(cases.FilingYear, cases.CourtLevel, margins=True))

    pending = cases[cases.PendingAge.notna()]
    show("10b. Age of pending cases",
         pending.groupby("CourtLevel").PendingAge.describe()
                [["count", "mean", "50%", "max"]].round(1))
    show("10c. Pending over one year",
         f"{(pending.PendingAge > 365).sum():,} of {len(pending):,} "
         f"({(pending.PendingAge > 365).mean() * 100:.1f}%)")

    # ---- Section 11: data quality -----------------------------------------
    checks = {
        "Disposition dated before filing":
            int((cases.DispositionDate < cases.FilingDate).sum()),
        "Filing date after as-of date":
            int((cases.FilingDate > ASOF).sum()),
        "Closed case with no disposition":
            int(((cases.CaseStatus == "Closed") & cases.CaseDisposition.isna()).sum()),
        "Case carrying no charges":
            int((cases.ChargeCount == 0).sum()),
        "Offense with no parent case":
            int((~offenses.CaseID.isin(cases_raw.CaseID)).sum()),
        "Sentence with no parent case":
            int((~sentences.CaseID.isin(cases_raw.CaseID)).sum()),
        "Defendants with no case":
            int(len(defendants) - defendants.PersonID.isin(
                load("03_CasePersonInvolvement.csv").PersonID).sum()),
    }
    show("11. Data quality exceptions", pd.Series(checks).to_string())

    results_dir = ROOT / "results"
    results_dir.mkdir(exist_ok=True)
    (results_dir / "findings.txt").write_text("\n".join(out), encoding="utf-8")
    print(f"\nWrote {results_dir / 'findings.txt'}")


if __name__ == "__main__":
    sys.exit(main())
