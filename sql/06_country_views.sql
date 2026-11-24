-- =====================================================================
-- 06_country_views.sql   |   OPTIONAL: show country tables like the reference Excel sheets
--
-- The tables keep real DATE columns (fast, sortable, no ambiguity).
-- Each country's own column names and date style are a VIEW on top.
-- Source of the layouts: AUS.xlsx, USA.csv, IND.csv (in /reference).
-- Countries without a reference sheet (CAN, PHL) just use the standard table.
-- =====================================================================

-- AUS: dates as 2022-05-11
CREATE OR REPLACE VIEW V_AUS AS
SELECT MEMBER_ID                                   AS "Unique ID",
       MEMBER_NAME                                 AS "Member Name",
       TIER_CODE                                   AS "Tier Type",
       TO_CHAR(DOB, 'YYYY-MM-DD')                  AS "Date of Birth",
       TO_CHAR(ENROLLMENT_DATE, 'YYYY-MM-DD')      AS "Date of Enrollment",
       TO_CHAR(LAST_FLIGHT_DATE, 'YYYY-MM-DD')     AS "Date of Flight"
FROM TABLE_AUS;

-- USA: dates as month+day+year with no separators and no padding: 6152022
CREATE OR REPLACE VIEW V_USA AS
SELECT MEMBER_ID                                   AS "ID",
       MEMBER_NAME                                 AS "Name",
       TIER_CODE                                   AS "TierCode",
       MONTH(ENROLLMENT_DATE) || DAY(ENROLLMENT_DATE) || YEAR(ENROLLMENT_DATE)       AS "EnrollmentDate",
       MONTH(LAST_FLIGHT_DATE) || DAY(LAST_FLIGHT_DATE) || YEAR(LAST_FLIGHT_DATE)    AS "FlightDate"
FROM TABLE_USA;

-- IND: dates as 8/13/1982. "Individual" (I/C) is not in the flat file, so it stays empty.
CREATE OR REPLACE VIEW V_IND AS
SELECT MEMBER_ID                                   AS "ID",
       MEMBER_NAME                                 AS "Name",
       MONTH(DOB) || '/' || DAY(DOB) || '/' || YEAR(DOB)                              AS "DOB",
       TIER_CODE                                   AS "TierCode",
       MONTH(ENROLLMENT_DATE) || '/' || DAY(ENROLLMENT_DATE) || '/' || YEAR(ENROLLMENT_DATE)     AS "EnrollmentDate",
       NULL::VARCHAR                               AS "Individual",
       MONTH(LAST_FLIGHT_DATE) || '/' || DAY(LAST_FLIGHT_DATE) || '/' || YEAR(LAST_FLIGHT_DATE)  AS "Flight Date"
FROM TABLE_IND;
