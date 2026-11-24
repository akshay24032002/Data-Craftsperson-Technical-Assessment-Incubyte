-- =====================================================================
-- 04_redemptions.sql   |   Deliverable 4: JSON feed -> flat table -> join to member
--
--   JSON files -> RAW_REDEMPTION (VARIANT, untouched)
--              -> FLATTEN: one row per transaction -> FACT_REDEMPTION
--              -> LEFT JOIN MEMBER_CURRENT (on member_id)
-- =====================================================================

-- A) Land the JSON as-is. Each file = one JSON object per member (or an array of them).
COPY INTO RAW_REDEMPTION (PAYLOAD, SOURCE_FILE, BATCH_ID)
FROM (SELECT $1, METADATA$FILENAME, REGEXP_SUBSTR(METADATA$FILENAME, '[0-9]{8}')
      FROM @SKYPOINTS_STAGE/redemption/)
FILE_FORMAT = (TYPE = JSON STRIP_OUTER_ARRAY = TRUE)
PATTERN = '.*[.]json';

-- B) Flatten. The redemptions[] array becomes one row per element (LATERAL FLATTEN).
--    TRY_ functions: a bad date or non-numeric miles value becomes NULL, the load keeps going.
CREATE OR REPLACE TEMPORARY TABLE BATCH_TXN AS
SELECT
  f.VALUE:txn_id::VARCHAR                                    AS TXN_ID,
  r.PAYLOAD:member_id::VARCHAR                               AS MEMBER_ID,
  TRY_TO_DATE(f.VALUE:txn_date::VARCHAR, 'YYYYMMDD')         AS TXN_DATE,
  f.VALUE:partner::VARCHAR                                   AS PARTNER,
  TRY_TO_NUMBER(f.VALUE:miles_redeemed::VARCHAR)             AS MILES_REDEEMED,
  UPPER(f.VALUE:status::VARCHAR)                             AS STATUS,
  TRY_TO_DATE(r.PAYLOAD:feed_date::VARCHAR, 'YYYYMMDD')      AS FEED_DATE,
  r.BATCH_ID                                                 AS BATCH_ID
FROM RAW_REDEMPTION r,
     LATERAL FLATTEN(INPUT => r.PAYLOAD:redemptions) f
WHERE r.BATCH_ID = $BATCH_ID
-- partners re-send the same txn (PENDING today, COMPLETED tomorrow): keep the newest within the batch
QUALIFY ROW_NUMBER() OVER (PARTITION BY f.VALUE:txn_id::VARCHAR
                           ORDER BY TRY_TO_DATE(r.PAYLOAD:feed_date::VARCHAR, 'YYYYMMDD') DESC, r.LOAD_TS DESC) = 1;

-- C) Upsert into the fact table. Key = TXN_ID, so a re-sent txn updates instead of duplicating.
MERGE INTO FACT_REDEMPTION t
USING BATCH_TXN s ON t.TXN_ID = s.TXN_ID
WHEN MATCHED AND s.FEED_DATE >= t.FEED_DATE THEN UPDATE SET
     t.STATUS = s.STATUS, t.MILES_REDEEMED = s.MILES_REDEEMED, t.TXN_DATE = s.TXN_DATE,
     t.FEED_DATE = s.FEED_DATE, t.BATCH_ID = s.BATCH_ID
WHEN NOT MATCHED THEN INSERT (TXN_ID, MEMBER_ID, TXN_DATE, PARTNER, MILES_REDEEMED, STATUS, FEED_DATE, BATCH_ID)
     VALUES (s.TXN_ID, s.MEMBER_ID, s.TXN_DATE, s.PARTNER, s.MILES_REDEEMED, s.STATUS, s.FEED_DATE, s.BATCH_ID);

-- D) HOW TO JOIN BACK TO THE MEMBER: join on MEMBER_ID to MEMBER_CURRENT (NOT to the country tables).
--    Why: MEMBER_CURRENT has exactly 1 row per member, so the join can never multiply rows,
--    and we avoid a UNION of 200 country tables. It also always knows the member's CURRENT country.
--    LEFT JOIN: a transaction for an unknown member is kept and flagged, never silently dropped.
CREATE OR REPLACE VIEW V_REDEMPTION_WITH_MEMBER AS
SELECT r.*, m.MEMBER_NAME, m.COUNTRY, m.TIER_CODE, (m.MEMBER_ID IS NOT NULL) AS MEMBER_FOUND
FROM FACT_REDEMPTION r
LEFT JOIN MEMBER_CURRENT m ON m.MEMBER_ID = r.MEMBER_ID;

-- Example business question: miles redeemed per country and tier
SELECT COUNTRY, TIER_CODE, SUM(MILES_REDEEMED) AS MILES
FROM V_REDEMPTION_WITH_MEMBER
WHERE STATUS = 'COMPLETED' AND MEMBER_FOUND
GROUP BY 1, 2 ORDER BY MILES DESC;
