-- =====================================================================
-- 01_ddl.sql   |   Deliverable 1: raw/landing, staging, country tables
--
-- The whole design in one line:
--   RAW (text, as received) -> STG (typed, clean, derived)
--       -> MEMBER_CURRENT (1 row per member, latest wins) -> TABLE_<COUNTRY>
--
-- Rule of thumb: RAW never rejects a row. STG decides what is bad.
-- =====================================================================

-- Where the daily files land (S3 / Azure / GCS in real life).
CREATE STAGE IF NOT EXISTS SKYPOINTS_STAGE;

-- ---------- Config: messy source country code -> one standard code ----------
-- Standard codes match the reference sheets (AUS, USA, IND). Add a row to onboard a country.
CREATE OR REPLACE TABLE REF_COUNTRY (RAW_CODE VARCHAR, COUNTRY_CODE VARCHAR);
INSERT INTO REF_COUNTRY VALUES
  ('USA','USA'), ('IND','IND'), ('CAN','CAN'), ('AUS','AUS'), ('AU','AUS'), ('PHIL','PHL'), ('PHL','PHL');

-- ---------- Two tiny helper functions, used everywhere ----------
-- trim spaces, turn '' and the TEXT 'NULL' into a real NULL
CREATE OR REPLACE FUNCTION CLEAN(V VARCHAR) RETURNS VARCHAR
AS $$ NULLIF(NULLIF(TRIM(V), ''), 'NULL') $$;

-- text -> date. A bad value (month 13) gives NULL, it does NOT fail the load.
-- The sample DOB 3051985 lost its leading zero (03051985), so a 7-digit value gets the zero back.
CREATE OR REPLACE FUNCTION PARSE_DT(V VARCHAR, FMT VARCHAR) RETURNS DATE
AS $$ TRY_TO_DATE(IFF(REGEXP_LIKE(CLEAN(V), '[0-9]{7}'), '0' || CLEAN(V), CLEAN(V)), FMT) $$;

-- ---------- Layer 1: RAW (all text, exactly as received) ----------
CREATE TABLE IF NOT EXISTS RAW_MEMBER (
  REC_TYPE VARCHAR,                       -- H = header line, D = detail line
  MEMBER_NAME VARCHAR, MEMBER_ID VARCHAR, ENROLLMENT_DATE VARCHAR, LAST_FLIGHT_DATE VARCHAR,
  TIER_CODE VARCHAR, AGENT_NAME VARCHAR, STATE VARCHAR, COUNTRY VARCHAR,
  POST_CODE VARCHAR,                      -- text, not INT (an INT would lose the zero in 02134). Not in the sample header.
  DOB VARCHAR, IS_ACTIVE VARCHAR,
  SOURCE_FILE VARCHAR,                    -- audit: which file
  FILE_ROW NUMBER,                        -- audit + tie-breaker: line number inside the file
  BATCH_ID VARCHAR,                       -- file date (YYYYMMDD): lets us re-run one day safely
  LOAD_TS TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

-- ---------- Layer 2: STG (typed + clean + derived) ----------
-- Lengths from the spec are checked in 05_validations (a too-long value must not crash the load).
CREATE TABLE IF NOT EXISTS STG_MEMBER (
  MEMBER_ID VARCHAR,                      -- identity of a member (what the JSON feed also uses)
  MEMBER_NAME VARCHAR,
  ENROLLMENT_DATE DATE, LAST_FLIGHT_DATE DATE,
  TIER_CODE VARCHAR, AGENT_NAME VARCHAR, STATE VARCHAR, COUNTRY VARCHAR, POST_CODE VARCHAR,
  DOB DATE, IS_ACTIVE VARCHAR,
  AGE NUMBER(3),                          -- derived from DOB
  STALE_MEMBER BOOLEAN,                   -- derived from LAST_FLIGHT_DATE: more than 90 days ago
  VERSION_KEY VARCHAR,                    -- derived: "how new is this record" -> newest enrollment, then newest flight
  SOURCE_FILE VARCHAR, FILE_ROW NUMBER, BATCH_ID VARCHAR, LOAD_TS TIMESTAMP_NTZ,
  REJECT_REASON VARCHAR                   -- NULL = good row. Anything else = quarantined.
);

-- ---------- Layer 3: one row per member (the "current" truth) ----------
CREATE TABLE IF NOT EXISTS MEMBER_CURRENT LIKE STG_MEMBER;
ALTER TABLE MEMBER_CURRENT CLUSTER BY (MEMBER_ID);       -- every lookup is by member id

-- ---------- Layer 4: country tables (same columns, one per country) ----------
-- Real DATE columns here. The reference-sheet look (06_country_views.sql) is done with views.
-- New countries are created automatically by LOAD_COUNTRY_TABLES (see 03). These five are the sample's.
CREATE TABLE IF NOT EXISTS TABLE_IND LIKE MEMBER_CURRENT;
CREATE TABLE IF NOT EXISTS TABLE_USA LIKE MEMBER_CURRENT;
CREATE TABLE IF NOT EXISTS TABLE_PHL LIKE MEMBER_CURRENT;
CREATE TABLE IF NOT EXISTS TABLE_CAN LIKE MEMBER_CURRENT;
CREATE TABLE IF NOT EXISTS TABLE_AUS LIKE MEMBER_CURRENT;

-- ---------- Redemptions (JSON) ----------
CREATE TABLE IF NOT EXISTS RAW_REDEMPTION (
  PAYLOAD VARIANT,                        -- the JSON object, untouched
  SOURCE_FILE VARCHAR, BATCH_ID VARCHAR, LOAD_TS TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

CREATE TABLE IF NOT EXISTS FACT_REDEMPTION (    -- one row per transaction
  TXN_ID VARCHAR, MEMBER_ID VARCHAR, TXN_DATE DATE, PARTNER VARCHAR,
  MILES_REDEEMED NUMBER(18,0), STATUS VARCHAR, FEED_DATE DATE, BATCH_ID VARCHAR
) CLUSTER BY (TXN_DATE);                        -- queries filter by date
