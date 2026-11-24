-- =====================================================================
-- 02_load_staging.sql   |   Deliverable 2: load staging + Age + Stale_Member
--
--   flat file -> RAW_MEMBER (COPY, text)  ->  STG_MEMBER (clean, typed, derived)
--
-- The orchestrator (Airflow / Snowflake Task) sets the batch date once per run.
-- =====================================================================
SET BATCH_ID = '20261124';

-- ---------------------------------------------------------------------
-- A) COPY the flat file into RAW. Everything is text.
--    A line looks like |D|Elena|223457|... so $1 is empty, $2 is H/D, the fields start at $3.
--    COPY remembers which files it already loaded, so a re-run does not double-load.
--    Batch id = the YYYYMMDD in the file name.
-- ---------------------------------------------------------------------
COPY INTO RAW_MEMBER (REC_TYPE, MEMBER_NAME, MEMBER_ID, ENROLLMENT_DATE, LAST_FLIGHT_DATE, TIER_CODE,
                      AGENT_NAME, STATE, COUNTRY, DOB, IS_ACTIVE, SOURCE_FILE, FILE_ROW, BATCH_ID)
FROM (SELECT $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12,
             METADATA$FILENAME, METADATA$FILE_ROW_NUMBER, REGEXP_SUBSTR(METADATA$FILENAME, '[0-9]{8}')
      FROM @SKYPOINTS_STAGE/member/)
FILE_FORMAT = (TYPE = CSV FIELD_DELIMITER = '|' ERROR_ON_COLUMN_COUNT_MISMATCH = FALSE)   -- short rows load with NULLs, caught below
PATTERN = '.*member_profile.*[.]txt';

-- ---------------------------------------------------------------------
-- B) RAW -> STG. Clean, type, derive, and mark bad rows. Nothing is dropped here.
-- ---------------------------------------------------------------------
DELETE FROM STG_MEMBER WHERE BATCH_ID = $BATCH_ID;       -- makes this step safe to re-run

INSERT INTO STG_MEMBER
WITH p AS (                                              -- p = "parsed"
  SELECT
    CLEAN(r.MEMBER_ID)                                   AS MEMBER_ID,
    CLEAN(r.MEMBER_NAME)                                 AS MEMBER_NAME,
    PARSE_DT(r.ENROLLMENT_DATE,  'YYYYMMDD')             AS ENROLLMENT_DATE,
    PARSE_DT(r.LAST_FLIGHT_DATE, 'YYYYMMDD')             AS LAST_FLIGHT_DATE,
    UPPER(CLEAN(r.TIER_CODE))                            AS TIER_CODE,
    CLEAN(r.AGENT_NAME)                                  AS AGENT_NAME,
    CLEAN(r.STATE)                                       AS STATE,
    COALESCE(c.COUNTRY_CODE, UPPER(CLEAN(r.COUNTRY)))    AS COUNTRY,           -- AU -> AUS, PHIL -> PHL
    (c.COUNTRY_CODE IS NULL)                             AS COUNTRY_UNMAPPED,  -- true for missing OR unknown country
    CLEAN(r.POST_CODE)                                   AS POST_CODE,
    PARSE_DT(r.DOB, 'MMDDYYYY')                          AS DOB,               -- assumption: MMDDYYYY (confirm with source)
    UPPER(CLEAN(r.IS_ACTIVE))                            AS IS_ACTIVE,
    r.SOURCE_FILE, r.FILE_ROW, r.BATCH_ID, r.LOAD_TS
  FROM RAW_MEMBER r
  LEFT JOIN REF_COUNTRY c ON c.RAW_CODE = UPPER(CLEAN(r.COUNTRY))
  WHERE r.REC_TYPE = 'D' AND r.BATCH_ID = $BATCH_ID
)
SELECT
  MEMBER_ID, MEMBER_NAME, ENROLLMENT_DATE, LAST_FLIGHT_DATE, TIER_CODE, AGENT_NAME,
  STATE, COUNTRY, POST_CODE, DOB, IS_ACTIVE,

  -- Derived 1: Age = COMPLETED years (subtract 1 if the birthday has not happened yet this year)
  DATEDIFF('year', DOB, CURRENT_DATE)
    - IFF(TO_CHAR(CURRENT_DATE, 'MMDD') < TO_CHAR(DOB, 'MMDD'), 1, 0)                 AS AGE,

  -- Derived 2: stale = MORE than 90 days since last flight. No flight date -> NULL (unknown), not TRUE.
  DATEDIFF('day', LAST_FLIGHT_DATE, CURRENT_DATE) > 90                                AS STALE_MEMBER,

  -- Derived 3: the spec has no Updated_At, so the newest ENROLLMENT date is the newest record;
  --            a tie is broken by the newest last-flight date. Glued into one sortable text.
  TO_CHAR(ENROLLMENT_DATE, 'YYYYMMDD') || '-'
    || TO_CHAR(COALESCE(LAST_FLIGHT_DATE, DATE '1900-01-01'), 'YYYYMMDD')             AS VERSION_KEY,

  SOURCE_FILE, FILE_ROW, BATCH_ID, LOAD_TS,

  -- Fatal problems only (mandatory fields per spec + a country we can route to). NULL = row is good.
  NULLIF(ARRAY_TO_STRING(ARRAY_CONSTRUCT_COMPACT(
      IFF(MEMBER_NAME IS NULL,       'NAME_MISSING', NULL),
      IFF(MEMBER_ID IS NULL,         'ID_MISSING', NULL),
      IFF(ENROLLMENT_DATE IS NULL,   'ENROLLMENT_DATE_MISSING_OR_INVALID', NULL),
      IFF(COUNTRY_UNMAPPED,          'COUNTRY_UNKNOWN', NULL),
      IFF(LENGTH(MEMBER_ID) > 18,    'ID_TOO_LONG', NULL)
  ), ';'), '')                                                                        AS REJECT_REASON
FROM p;

-- Tip: the stale flag changes every day. For reports use this view, not the stored value:
CREATE OR REPLACE VIEW V_MEMBER_CURRENT AS
SELECT *, DATEDIFF('day', LAST_FLIGHT_DATE, CURRENT_DATE) > 90 AS STALE_MEMBER_TODAY FROM MEMBER_CURRENT;
