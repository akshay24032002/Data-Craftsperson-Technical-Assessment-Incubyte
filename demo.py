"""
SkyPoints demo - a tiny local copy of the Snowflake pipeline in /sql.

Input : flat file(s) |H|...|D|...  +  redemption JSON.
Steps : 1 READ  ->  2 CLEAN + DERIVE  ->  3 VALIDATE  ->  4 LATEST WINS + SPLIT BY COUNTRY  ->  5 JSON + JOIN
The AUS / USA / IND Excel sheets in /reference show how each country table should look.

NOTE: pandas is only for the live demo. At billions of rows the same logic runs as SQL in Snowflake (/sql).
"""
import json
from datetime import date
from pathlib import Path

import pandas as pd

HERE = Path(__file__).parent
DATA, OUT = HERE / "data", HERE / "output"

COLS = ["Member_Name", "Member_Id", "Enrollment_Date", "Last_Flight_Date", "Tier_Code",
        "Agent_Name", "State", "Country", "Post_Code", "DOB", "Is_Active"]
COUNTRY_MAP = {"AU": "AUS", "PHIL": "PHL"}          # messy source code -> one standard code
KNOWN_COUNTRIES = {"USA", "IND", "CAN", "AUS", "PHL"}
KNOWN_TIERS = {"PLT", "GLD", "SLV"}

# How each country table looks in the reference Excel sheets (column names + date style).
LAYOUTS = {
    "AUS": dict(fmt=lambda d: f"{d:%Y-%m-%d}",                        # 2022-05-11
                cols=[("Unique ID", "Member_Id"), ("Member Name", "Member_Name"), ("Tier Type", "Tier_Code"),
                      ("Date of Birth", "DOB"), ("Date of Enrollment", "Enrollment_Date"),
                      ("Date of Flight", "Last_Flight_Date")]),
    "USA": dict(fmt=lambda d: f"{d.month}{d.day}{d.year}",            # 6152022
                cols=[("ID", "Member_Id"), ("Name", "Member_Name"), ("TierCode", "Tier_Code"),
                      ("EnrollmentDate", "Enrollment_Date"), ("FlightDate", "Last_Flight_Date")]),
    "IND": dict(fmt=lambda d: f"{d.month}/{d.day}/{d.year}",          # 8/13/1982
                cols=[("ID", "Member_Id"), ("Name", "Member_Name"), ("DOB", "DOB"), ("TierCode", "Tier_Code"),
                      ("EnrollmentDate", "Enrollment_Date"), ("Individual", "Customer_Type"),
                      ("Flight Date", "Last_Flight_Date")]),
}


# --------------------------------------------------------------------------
# STEP 1 - READ (everything stays text)
# --------------------------------------------------------------------------
def read_flat(path):
    """|H| line = column names, |D| lines = data. Leading/trailing pipes are stripped."""
    lines = [l.strip().strip("|").split("|") for l in open(path) if l.strip()]
    header = lines[0][1:]
    rows = [l[1:] for l in lines[1:] if l[0] == "D"]
    rows = [(r + [None] * len(header))[:len(header)] for r in rows]    # short/long rows padded/cut; the
    return pd.DataFrame(rows, columns=header).assign(Source_File=Path(path).name)   # validation step catches the gaps


# --------------------------------------------------------------------------
# STEP 2 - CLEAN + DERIVE
# --------------------------------------------------------------------------
def clean(s):
    """Trim spaces; turn '' and the text 'NULL' into a real null."""
    return s.astype("string").str.strip().replace({"": pd.NA, "NULL": pd.NA})


def parse_date(s, fmt):
    """Text -> date. A bad value (month 13) becomes NaT instead of crashing.
    Excel/ETL ate the leading zero of 03051985 -> 3051985. A 7-digit number gets its zero back."""
    s = clean(s)
    lost_zero = ((s.str.len() == 7) & s.str.isdigit()).fillna(False)
    return pd.to_datetime(s.mask(lost_zero, "0" + s), format=fmt, errors="coerce")


def standardise(df):
    df = df.reindex(columns=COLS + ["Source_File"])
    df[COLS] = df[COLS].apply(clean)
    df["Enrollment_Date"] = parse_date(df["Enrollment_Date"], "%Y%m%d")
    df["Last_Flight_Date"] = parse_date(df["Last_Flight_Date"], "%Y%m%d")
    df["DOB"] = parse_date(df["DOB"], "%m%d%Y")             # assumption: DOB is MMDDYYYY (to confirm with source)
    df["Country"] = df["Country"].str.upper().replace(COUNTRY_MAP)
    df["Tier_Code"] = df["Tier_Code"].str.upper()
    return df


def add_derived(df, as_of):
    """Age = completed years. Stale = last flight more than 90 days ago."""
    dob = df["DOB"]
    had_birthday = (dob.dt.month * 100 + dob.dt.day) <= (as_of.month * 100 + as_of.day)
    df["Age"] = (as_of.year - dob.dt.year - (~had_birthday).astype(int)).astype("Int64")
    days = (as_of - df["Last_Flight_Date"]).dt.days
    df["Stale_Member"] = (days > 90).astype("boolean").where(days.notna())   # no flight date -> unknown, not True
    # "How new is this record": newest enrollment first, then newest last flight (YYYYMMDD glued together).
    df["Version_Key"] = (df["Enrollment_Date"].dt.strftime("%Y%m%d") + "-"
                         + df["Last_Flight_Date"].fillna(pd.Timestamp("1900-01-01")).dt.strftime("%Y%m%d"))
    return df


# --------------------------------------------------------------------------
# STEP 3 - VALIDATE
# --------------------------------------------------------------------------
def reject_reason(df):
    """Fatal problems: the row is quarantined, the job continues."""
    checks = {
        "NAME_MISSING": df["Member_Name"].isna(),
        "ID_MISSING": df["Member_Id"].isna(),
        "ENROLLMENT_DATE_MISSING_OR_INVALID": df["Enrollment_Date"].isna(),
        "COUNTRY_UNKNOWN": ~df["Country"].isin(KNOWN_COUNTRIES),
        "ID_TOO_LONG": df["Member_Id"].str.len() > 18,
    }
    reason = pd.Series("", index=df.index)
    for name, failed in checks.items():
        reason = reason + failed.fillna(False).map({True: name + ";", False: ""})
    return reason.str.rstrip(";")


def warnings(df):
    """Suspicious but loadable: the row is kept and reported."""
    rules = {
        "DOB_MISSING_OR_INVALID": df["DOB"].isna(),
        "DOB_IN_FUTURE": df["DOB"] > pd.Timestamp(date.today()),
        "AGE_IMPLAUSIBLE": df["Age"].notna() & ~df["Age"].between(0, 110),
        "FLIGHT_BEFORE_ENROLLMENT": df["Last_Flight_Date"] < df["Enrollment_Date"],
        "UNKNOWN_TIER": ~df["Tier_Code"].isin(KNOWN_TIERS),
        "SAME_ID_DIFFERENT_NAME": df.groupby("Member_Id")["Member_Name"].transform(lambda s: s.str.upper().nunique()) > 1,
        "SAME_NAME_DIFFERENT_ID": df.groupby(df["Member_Name"].str.upper())["Member_Id"].transform("nunique") > 1,
    }
    found = [df.loc[mask.fillna(False), ["Member_Id", "Member_Name"]].assign(Rule=rule) for rule, mask in rules.items()]
    return pd.concat(found, ignore_index=True)


# --------------------------------------------------------------------------
# STEP 4 - LATEST RECORD WINS (before splitting), THEN SPLIT BY COUNTRY
# --------------------------------------------------------------------------
def latest_wins(df):
    """Newest row per member wins and decides the country. The others are 'superseded'."""
    df = df.sort_values(["Member_Id", "Version_Key", "_seq"])      # _seq = file order, the last tie-breaker
    winners = df.drop_duplicates("Member_Id", keep="last")
    superseded = df.drop(winners.index)
    winner_country = winners.set_index("Member_Id")["Country"]
    return winners, superseded.assign(Moved_Country=superseded["Country"] != superseded["Member_Id"].map(winner_country))


def sheet_layout(df, country):
    """Show a country table the way the reference Excel sheet does (names + date style)."""
    layout, out = LAYOUTS[country], pd.DataFrame()
    for sheet_col, our_col in layout["cols"]:
        s = df[our_col] if our_col in df else pd.Series(pd.NA, index=df.index)   # e.g. 'Individual' is not in the flat file
        if pd.api.types.is_datetime64_any_dtype(s):
            s = s.map(lambda d: layout["fmt"](d) if pd.notna(d) else None)
        out[sheet_col] = s
    return out


# --------------------------------------------------------------------------
# STEP 5 - REDEMPTIONS (JSON)
# --------------------------------------------------------------------------
def flatten_redemptions(path):
    """One JSON object per member -> one row per transaction (same job as LATERAL FLATTEN)."""
    data = json.load(open(path))
    data = data if isinstance(data, list) else [data]
    tx = pd.json_normalize(data, record_path="redemptions", meta=["member_id", "feed_date"])
    tx["txn_date"] = pd.to_datetime(tx["txn_date"], format="%Y%m%d", errors="coerce")
    tx["feed_date"] = pd.to_datetime(tx["feed_date"], format="%Y%m%d", errors="coerce")
    return tx.sort_values("feed_date").drop_duplicates("txn_id", keep="last")   # re-sent txn: newest feed wins


def join_to_member(tx, members):
    cols = ["Member_Id", "Member_Name", "Country", "Tier_Code"]
    out = tx.merge(members[cols], left_on="member_id", right_on="Member_Id", how="left", validate="many_to_one")
    out["Member_Found"] = out["Member_Id"].notna()                   # unknown member: kept and flagged, not dropped
    return out


# --------------------------------------------------------------------------
def run(as_of=None):
    as_of = as_of or pd.Timestamp(date.today())
    (OUT / "country_tables").mkdir(parents=True, exist_ok=True)

    files = sorted(DATA.glob("member_profile*.txt"))                 # a day can have several files
    members = pd.concat([standardise(read_flat(f)) for f in files], ignore_index=True)
    members = add_derived(members, as_of)
    members["_seq"] = range(len(members))

    members["Reject_Reason"] = reject_reason(members)
    rejected = members[members["Reject_Reason"] != ""]
    good = members[members["Reject_Reason"] == ""]

    winners, superseded = latest_wins(good)
    for country, rows in winners.groupby("Country"):
        rows = rows.drop(columns=["_seq", "Reject_Reason"])
        rows.to_csv(OUT / "country_tables" / f"Table_{country}.csv", index=False)
        if country in LAYOUTS:
            sheet_layout(rows, country).to_csv(OUT / "country_tables" / f"Table_{country}_sheet_layout.csv", index=False)

    tx = flatten_redemptions(DATA / "redemption_feed.json")
    joined = join_to_member(tx, winners)

    rejected.to_csv(OUT / "rejected_rows.csv", index=False)
    warnings(good).to_csv(OUT / "warnings.csv", index=False)
    superseded.to_csv(OUT / "superseded_rows.csv", index=False)
    tx.to_csv(OUT / "redemption_flat.csv", index=False)
    joined.to_csv(OUT / "redemption_with_member.csv", index=False)
    return dict(members=members, rejected=rejected, winners=winners, superseded=superseded, tx=tx, joined=joined)


if __name__ == "__main__":
    r = run()
    print(f"rows read: {len(r['members'])} | rejected: {len(r['rejected'])} | "
          f"superseded: {len(r['superseded'])} | loaded: {len(r['winners'])}")
    print("\nREJECTED:\n", r["rejected"][["Member_Name", "Member_Id", "Reject_Reason"]].to_string(index=False))
    s = r["superseded"]
    print("\nSUPERSEDED (older record dropped):\n",
          s[["Member_Name", "Country", "Enrollment_Date", "Moved_Country"]].to_string(index=False))
    print("\nROWS PER COUNTRY TABLE:\n", r["winners"].groupby("Country").size().to_string())
    print("\nREDEMPTIONS + MEMBER:\n", r["joined"][["txn_id", "member_id", "status", "miles_redeemed",
                                                    "Member_Name", "Country", "Member_Found"]].to_string(index=False))
