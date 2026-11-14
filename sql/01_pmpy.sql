-- Cost per member per year (PMPY) by service type, 2008-2010.
--
-- Denominator: fee-for-service member-months. Months in a Medicare Advantage
-- (HMO) plan are excluded because their claims are not in fee-for-service data.
-- Medical member-months = months with both Part A and Part B, minus HMO months.
-- Drug PMPY uses Part D months as its own denominator.
--
-- Data completeness: monthly claim volume is roughly stable Mar 2008 - Dec 2009,
-- ramps up in Jan-Feb 2008 (stays that began in 2007 are missing) and trails off
-- steadily through 2010 (Dec 2010 has ~10% of normal inpatient volume). 2009 is
-- the only complete year; 2008 and 2010 are shown with a flag.

CREATE OR REPLACE TABLE member_year AS
SELECT
    b.year, b.member_id, b.n_chronic,
    greatest(least(b.part_a_months, b.part_b_months) - b.hmo_months, 0) AS med_months,
    b.part_d_months                                                        AS rx_months
FROM bene b;

CREATE OR REPLACE TABLE spend_member_year AS
WITH ip_y  AS (SELECT member_id, year(admit_dt)   AS year, sum(paid)       AS ip  FROM ip      GROUP BY ALL),
     op_y  AS (SELECT member_id, year(service_dt) AS year, sum(paid)       AS op  FROM op      GROUP BY ALL),
     car_y AS (SELECT member_id, year(service_dt) AS year, sum(paid)       AS car FROM carrier GROUP BY ALL),
     rx_y  AS (SELECT member_id, year(service_dt) AS year, sum(total_cost) AS rx  FROM rx      GROUP BY ALL)
SELECT
    m.*,
    coalesce(ip_y.ip, 0)   AS ip,
    coalesce(op_y.op, 0)   AS op,
    coalesce(car_y.car, 0) AS carrier,
    coalesce(rx_y.rx, 0)   AS rx
FROM member_year m
LEFT JOIN ip_y  USING (member_id, year)
LEFT JOIN op_y  USING (member_id, year)
LEFT JOIN car_y USING (member_id, year)
LEFT JOIN rx_y  USING (member_id, year);

-- PMPY by year and service type.
CREATE OR REPLACE TABLE out_pmpy_by_year AS
SELECT
    year,
    CASE year WHEN 2009 THEN 'complete'
              WHEN 2008 THEN 'Jan-Feb under-captured'
              ELSE 'claims trail off; not usable' END AS data_note,
    count(*)                                         AS members,
    round(sum(med_months) / 12.0, 0)                 AS medical_member_years,
    round(sum(ip)      / (sum(med_months) / 12.0), 0) AS inpatient_pmpy,
    round(sum(op)      / (sum(med_months) / 12.0), 0) AS outpatient_pmpy,
    round(sum(carrier) / (sum(med_months) / 12.0), 0) AS physician_pmpy,
    round(sum(ip + op + carrier) / (sum(med_months) / 12.0), 0) AS medical_pmpy,
    round(sum(rx) / nullif(sum(rx_months) / 12.0, 0), 0)       AS drug_pmpy
FROM spend_member_year
WHERE med_months > 0
GROUP BY year
ORDER BY year;

-- Medical PMPY by number of chronic conditions: the classic "cost concentrates
-- in the multi-morbid" table.
CREATE OR REPLACE TABLE out_pmpy_by_chronic AS
SELECT
    CASE WHEN n_chronic >= 5 THEN '5+' ELSE n_chronic::VARCHAR END AS chronic_conditions,
    count(*)                                                       AS members,
    round(100.0 * count(*) / sum(count(*)) OVER (), 1)             AS pct_of_members,
    round(sum(ip + op + carrier) / (sum(med_months) / 12.0), 0)    AS medical_pmpy,
    round(100.0 * sum(ip + op + carrier) / sum(sum(ip + op + carrier)) OVER (), 1) AS pct_of_spend
FROM spend_member_year
WHERE med_months > 0 AND year = 2009
GROUP BY 1
ORDER BY 1;

-- Spend concentration: share of medical spend from the costliest 1% / 5% / 20%.
CREATE OR REPLACE TABLE out_spend_concentration AS
WITH r AS (
    SELECT ip + op + carrier AS spend,
           percent_rank() OVER (ORDER BY ip + op + carrier DESC) AS pr
    FROM spend_member_year
    WHERE med_months = 12 AND year = 2009
)
SELECT top_pct, round(100.0 * sum(spend) FILTER (WHERE pr < top_pct / 100.0) / sum(spend), 1) AS pct_of_spend
FROM r, (VALUES (1), (5), (20), (50)) t(top_pct)
GROUP BY top_pct
ORDER BY top_pct;

-- Reconciliation: claims-based totals vs. the beneficiary summary file's own
-- annual Medicare payment fields. Large gaps would mean a loading bug.
CREATE OR REPLACE TABLE out_reconciliation AS
SELECT
    s.year,
    round(sum(s.ip))          AS ip_from_claims,      round(sum(b.MEDREIMB_IP))  AS ip_from_summary,
    round(sum(s.op))          AS op_from_claims,      round(sum(b.MEDREIMB_OP))  AS op_from_summary,
    round(sum(s.carrier))     AS carrier_from_claims, round(sum(b.MEDREIMB_CAR)) AS carrier_from_summary
FROM spend_member_year s
JOIN bene b USING (member_id, year)
GROUP BY s.year
ORDER BY s.year;

-- Monthly claim counts, used to choose the complete-data window.
CREATE OR REPLACE TABLE out_monthly_claims AS
SELECT month, ip_admissions, op_claims, carrier_claims
FROM (SELECT date_trunc('month', admit_dt) AS month, count(*) AS ip_admissions FROM ip GROUP BY 1)
FULL JOIN (SELECT date_trunc('month', service_dt) AS month, count(*) AS op_claims FROM op GROUP BY 1) USING (month)
FULL JOIN (SELECT date_trunc('month', service_dt) AS month, count(*) AS carrier_claims FROM carrier GROUP BY 1) USING (month)
WHERE month >= DATE '2008-01-01'
ORDER BY month;
