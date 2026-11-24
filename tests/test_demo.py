"""Small tests - one per business rule, so each one is easy to explain."""
import sys
from pathlib import Path

import pandas as pd

ROOT = Path(__file__).parent.parent
sys.path.insert(0, str(ROOT))
import demo

AS_OF = pd.Timestamp("2026-11-24")
R = demo.run(as_of=AS_OF)


def test_dates_parse_and_bad_ones_become_null():
    good = demo.parse_date(pd.Series(["3051985", "12131997"]), "%m%d%Y")     # 7 digits: leading zero restored
    assert good.tolist() == [pd.Timestamp("1985-03-05"), pd.Timestamp("1997-12-13")]
    assert demo.parse_date(pd.Series(["20211313", "NULL"]), "%Y%m%d").isna().all()   # month 13 and 'NULL' -> null, no crash


def test_age_is_completed_years_and_stale_is_over_90_days():
    df = pd.DataFrame({"DOB": pd.to_datetime(["1985-03-05", "1998-12-01"]),
                       "Last_Flight_Date": pd.to_datetime(["2026-08-26", "2026-08-25"]),   # 90 and 91 days before AS_OF
                       "Enrollment_Date": pd.to_datetime(["2010-01-01", "2010-01-01"])})
    out = demo.add_derived(df, AS_OF)
    assert out["Age"].tolist() == [41, 27]                  # Dec 1 birthday has not happened yet
    assert out["Stale_Member"].tolist() == [False, True]    # exactly 90 days is NOT stale


def test_missing_flight_date_is_unknown_not_stale():
    lena = R["winners"].set_index("Member_Name").loc["Lena"]
    assert pd.isna(lena["Stale_Member"])


def test_bad_rows_are_rejected_with_a_reason():
    rej = R["rejected"].set_index("Member_Id")["Reject_Reason"]
    assert rej["300001"] == "ENROLLMENT_DATE_MISSING_OR_INVALID"     # month 13
    assert rej["300002"] == "NAME_MISSING"
    assert rej["300003"] == "COUNTRY_UNKNOWN"                        # UAE not in reference list
    assert rej["300006"] == "COUNTRY_UNKNOWN"                        # short row: fields missing


def test_latest_enrollment_wins_and_member_moves_country():
    w = R["winners"].set_index("Member_Id")
    assert w.loc["223458", "Country"] == "CAN"                       # Ravi: 2015 CAN record beat 2010 IND record
    assert str(w.loc["223457", "Enrollment_Date"].date()) == "2010-10-12"   # Elena: 2010 beat the old 2005 duplicate
    moved = R["superseded"].set_index("Member_Id")["Moved_Country"]
    assert moved["223458"] and not moved["223457"]


def test_one_row_per_member_and_in_exactly_one_country():
    w = R["winners"]
    assert w["Member_Id"].is_unique
    tables = [pd.read_csv(f, dtype=str) for f in (ROOT / "output/country_tables").glob("Table_???.csv")]
    assert sum(len(t) for t in tables) == len(w)                     # no member copied into two country tables
    assert "223458" not in pd.read_csv(ROOT / "output/country_tables/Table_IND.csv", dtype=str)["Member_Id"].values


def test_every_input_row_is_accounted_for():
    assert len(R["members"]) == len(R["rejected"]) + len(R["superseded"]) + len(R["winners"])


def test_country_codes_are_standardised():
    assert set(R["winners"]["Country"]) == {"USA", "IND", "CAN", "AUS", "PHL"}     # AU -> AUS, PHIL -> PHL


def test_sheet_layout_matches_reference_excel():
    for country in ["AUS", "USA", "IND"]:
        ref_cols = pd.read_csv(ROOT / "reference" / f"{country}.csv").columns.tolist()
        mine = demo.sheet_layout(R["winners"][R["winners"]["Country"] == country], country).columns.tolist()
        assert mine == ref_cols
    d = pd.Timestamp("2022-06-15")
    assert demo.LAYOUTS["USA"]["fmt"](d) == "6152022" and demo.LAYOUTS["IND"]["fmt"](d) == "6/15/2022"


def test_json_flattened_and_resent_txn_not_duplicated():
    tx = R["tx"].set_index("txn_id")
    assert len(tx) == 3 and tx.loc["RX10092", "status"] == "COMPLETED"   # newest feed wins over PENDING


def test_redemption_join_keeps_unknown_members_flagged():
    j = R["joined"].set_index("txn_id")
    assert j.loc["RX10091", "Member_Name"] == "Elena" and not j.loc["RX10093", "Member_Found"]


if __name__ == "__main__":          # python tests/test_demo.py   (pytest also works)
    for name, fn in list(globals().items()):
        if name.startswith("test_"):
            fn()
            print("PASS", name)
