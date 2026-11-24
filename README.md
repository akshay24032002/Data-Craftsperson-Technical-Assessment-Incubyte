# SkyPoints – Member & Redemption Pipeline

> Small on purpose: **5 steps, 4 ideas, 6 short SQL files.** Easy to explain in 5 minutes.

## 1. The problem in 30 seconds
Every day we get a **flat file of members** (each row has a Country) and a **JSON feed of redemptions**.
- Put every member in **exactly one** country table (`Table_India`, `Table_USA`, …).
- If a member appears again with another country, the **latest record decides** the country.
- Add **Age** (from DOB) and **Stale_Member** (last flight > 90 days ago).
- Flatten the JSON and join it back to the member.
- Volume: **billions of rows per day.**

The AUS / USA / IND sheets in `/reference` are the **reference for how each country table looks** (column names and date style). They are not extra input.

## 2. What I noticed in the data

| What I saw | Why it matters | What the pipeline does |
|---|---|---|
| Country codes are inconsistent: `AU` in the flat file vs `AUS` in the reference sheet, and `PHIL` (not ISO) | Wrong table name / lost rows | `REF_COUNTRY` maps every code to one standard code |
| DOB `03051985` becomes `3051985` in the staging table (leading zero lost) | Date fails to parse | 7-digit value gets its zero back |
| Reference sheets: `6152022` (USA) is June 15, same lost-zero problem | Same bug appears in country data | Same rule; USA view re-creates that style |
| Reference sheets: month 13 `2021-13-13`, text `NULL` instead of a real null | Load would crash / wrong data | `TRY_` parsing → NULL; mandatory date missing → row rejected |
| 3 sheets, 3 date styles (`2022-05-11`, `6152022`, `8/13/1982`) and different column names | Country tables must look different | Tables store real DATEs; **views** show each country's style |
| Header has 10 columns, the layout table lists 11 (Post Code missing) | Positional load breaks | Post Code optional, stored as text |
| Spec says Member Name is the key, but names repeat in real life | Two people merged into one | Identity = `Member_Id` (also what JSON uses); name/id clashes are reported as warnings |
| No update timestamp in the spec | "Latest" is undefined | Latest **enrollment date** wins; tie → latest last-flight date → later file row |

## 3. The design (one picture)

```
 member_profile_YYYYMMDD.txt
        │ COPY (text only, never fails)
        ▼
    RAW_MEMBER ──► STG_MEMBER ──────────► MEMBER_CURRENT ───────────► TABLE_IND / TABLE_USA / TABLE_AUS …
                   clean, real dates,     1 row per member,           only members changed today:
                   Age, Stale_Member,     latest enrollment wins      delete from every country table,
                   REJECT_REASON                                      insert into the winning one

 redemption.json ─► RAW_REDEMPTION ─► FLATTEN ─► FACT_REDEMPTION ─► LEFT JOIN MEMBER_CURRENT on member_id
                    (VARIANT)         1 row/txn   (MERGE on txn_id)
```

**Four ideas to say out loud**
1. **RAW never rejects, STG decides.** A bad value never crashes a billion-row load. It becomes a flagged row.
2. **Decide the winner first, route second.** Latest-wins runs across all countries *before* the split. Otherwise a mover sits in two tables.
3. **Config, not code.** A new country = one row in `REF_COUNTRY`. Its table is created automatically.
4. **Incremental and re-runnable.** Only today's batch is processed; every step is safe to run twice.

## 4. Why this works for billions of rows
| Choice | Why |
|---|---|
| Heavy work is **SQL inside Snowflake**; Python is only the demo | Pandas needs all data in memory, Snowflake scales out |
| `COPY INTO` from many files in parallel, remembers loaded files | Fast ingest, no double-loading |
| Incremental by `BATCH_ID` (file date) | Never reprocess history |
| `QUALIFY ROW_NUMBER()` to pick winners, delete+insert / `MERGE` to apply | Set-based, no row-by-row loops |
| Country step touches **only members changed today** | 1% churn = 1% of the work |
| Redemptions join to `MEMBER_CURRENT` (1 row/member), not 200 country tables | No UNION, no row multiplication |
| `FACT_REDEMPTION` clustered by `TXN_DATE`; `MEMBER_CURRENT` by `MEMBER_ID` | Pruning for common filters |
| Stale flag stored **and** offered as a daily-fresh view | A stored flag is wrong tomorrow |
| Circuit breaker: >1% rejects fails the run | A bad file must not reach the country tables |

## 5. Files = the deliverables

| PDF deliverable | File |
|---|---|
| 1. DDL (raw, staging, country) | `sql/01_ddl.sql` |
| 2. Load staging + Age + Stale_Member | `sql/02_load_staging.sql` |
| 3. Split by country, latest wins | `sql/03_country_split.sql` |
| 4. JSON flatten + join back | `sql/04_redemptions.sql` |
| 5. Validations | `sql/05_validations.sql` |
| (optional) reference-sheet look per country | `sql/06_country_views.sql` |
| 6. Live demo | `python demo.py` (same logic, runs locally in 1 second) |

## 6. Run the demo
```bash
pip install -r requirements.txt
python demo.py              # prints a summary, writes /output
python tests/test_demo.py   # 11 tests (pytest works too)
```
`data/member_profile_sample.txt` = the PDF sample, unchanged.
`data/member_profile_edge_cases.txt` = rows **I added** to demo a country move and bad data. `redemption_feed.json`: first object is the PDF sample; the other two are mine (a re-sent txn and an unknown member).

Expected: `rows read: 13 | rejected: 4 | superseded: 2 | loaded: 7`

| Story to show live | Result |
|---|---|
| Ravi: IND (enrolled 2010) then CAN (enrolled 2015) | Only in `Table_CAN`, gone from `Table_IND` |
| Elena twice in USA | Newest kept, older one superseded |
| Tara (month 13), blank name, country UAE, short row | 4 rows rejected, each with a reason |
| Lena has `NULL` flight date | Stale = unknown (not True) |
| Kiran flew before he enrolled | Loaded, with a warning |
| RX10092 sent as PENDING then COMPLETED | One row, COMPLETED |
| Txn for member 999999 | Kept, `Member_Found = False` |

## 7. Assumptions & questions for the source owner
1. **"Latest record"** = newest enrollment date (tie → last flight date → later file row). Is there a real `Updated_At`?
2. **Identity** = `Member_Id`. The spec lists Member Name as key; should it stay Name, or Name + DOB?
3. **DOB `03051985`** read as **MMDDYYYY**. Please confirm vs DDMMYYYY.
4. **Country tables:** I store real dates and show each country's style through views. If the business wants the formatted text *stored*, it is a small change.
5. The IND sheet has an `Individual` (I/C) column that the flat file lacks, so it stays empty.
6. `PHIL` mapped to ISO `PHL`; `AU` to `AUS` (the reference sheet is named AUS).
7. Screenshot headers were cut off (`Member N…`, `Enrollmen…`); I assumed *Member Name* and *EnrollmentDate*.

## 8. Honest limits
- The SQL targets Snowflake, but I could **not run it on a live account** here. The Python demo mirrors the same rules and is tested. Run files 01 → 06 once on a trial account before the interview and fix any syntax nit.
- The demo uses pandas: a demonstration, not the billion-row engine.

## 9. Suggested commit history
1. `docs: problem understanding and data issues`
2. `feat: DDL for raw, staging, member_current, country, redemption`
3. `feat: load flat file into RAW`
4. `feat: staging with Age, Stale_Member, reject reasons`
5. `feat: latest-wins and country routing`
6. `feat: flatten redemption JSON and join to member`
7. `feat: data-quality checks and reconciliation`
8. `feat: country reference views`
9. `test: unit tests and local demo`
