-- =====================================================================
-- 03_country_split.sql   |   Deliverable 3: split by country, "latest record wins"
--
-- Golden rule:  decide the WINNER first (across all countries),
--               THEN route the winner to exactly one country table.
-- If we routed first, a member who moved IND -> CAN would sit in both tables.
-- =====================================================================

-- STEP A: one winner per member for this batch. Newest enrollment wins; its country is the member's country.
CREATE OR REPLACE TEMPORARY TABLE BATCH_WINNERS AS
SELECT *
FROM STG_MEMBER
WHERE BATCH_ID = $BATCH_ID
  AND REJECT_REASON IS NULL                      -- bad rows never compete
QUALIFY ROW_NUMBER() OVER (
          PARTITION BY MEMBER_ID
          ORDER BY VERSION_KEY DESC, SOURCE_FILE DESC, FILE_ROW DESC   -- newest first; last two = tie-breakers
        ) = 1;

-- STEP B: merge winners into MEMBER_CURRENT (one row per member, across all days).
-- Pattern: "delete if the new one is as new or newer, then insert whoever is missing".
-- An OLD record arriving late finds a newer one already there -> it is simply skipped.
BEGIN;
  DELETE FROM MEMBER_CURRENT t
  USING BATCH_WINNERS s
  WHERE t.MEMBER_ID = s.MEMBER_ID
    AND s.VERSION_KEY >= t.VERSION_KEY;

  INSERT INTO MEMBER_CURRENT
  SELECT s.* FROM BATCH_WINNERS s
  WHERE NOT EXISTS (SELECT 1 FROM MEMBER_CURRENT t WHERE t.MEMBER_ID = s.MEMBER_ID);
COMMIT;
-- (Why not MERGE? It works too, but we would type all ~19 columns twice.)

-- STEP C: copy ONLY the members that changed in this batch into their country table.
-- Loops over REF_COUNTRY, so a new country needs no code change; its table is created on first use.
CREATE OR REPLACE PROCEDURE LOAD_COUNTRY_TABLES(P_BATCH_ID VARCHAR)
RETURNS VARCHAR
LANGUAGE SQL
AS
$$
DECLARE
  countries CURSOR FOR SELECT DISTINCT COUNTRY_CODE FROM REF_COUNTRY;
  tbl VARCHAR;
BEGIN
  FOR c IN countries DO
    tbl := 'TABLE_' || c.COUNTRY_CODE;
    EXECUTE IMMEDIATE 'CREATE TABLE IF NOT EXISTS ' || tbl || ' LIKE MEMBER_CURRENT';

    -- 1) remove every member that changed in this batch from THIS table.
    --    This is what handles movers: Ravi's old row disappears from TABLE_IND.
    --    It also makes re-running the same batch safe.
    EXECUTE IMMEDIATE
      'DELETE FROM ' || tbl || ' WHERE MEMBER_ID IN (SELECT MEMBER_ID FROM MEMBER_CURRENT WHERE BATCH_ID = ?)'
      USING (P_BATCH_ID);

    -- 2) insert the changed members whose winning country is THIS country.
    EXECUTE IMMEDIATE
      'INSERT INTO ' || tbl || ' SELECT * FROM MEMBER_CURRENT WHERE BATCH_ID = ? AND COUNTRY = ?'
      USING (P_BATCH_ID, c.COUNTRY_CODE);
  END FOR;
  RETURN 'country tables loaded for batch ' || P_BATCH_ID;
END;
$$;

CALL LOAD_COUNTRY_TABLES($BATCH_ID);
