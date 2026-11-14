-- Inpatient episodes: admission + 30 days after discharge.
--
-- An admission is an INDEX admission if the member had no discharge in the 30
-- days before it. Any admission within 30 days of an index discharge is a
-- READMISSION and belongs to that index episode (not a new episode).
-- Episode cost = index stay + readmissions + outpatient + physician (carrier)
-- claims dated from admission through discharge + 30 days.
-- Index admissions are limited to Mar 2008 - Nov 2009 so that the look-back and
-- the 30-day follow-up both fall inside the complete-data window (see 01_pmpy.sql).

CREATE OR REPLACE TABLE ip_ordered AS
SELECT
    *,
    lag(discharge_dt) OVER w AS prev_discharge_dt
FROM ip
WINDOW w AS (PARTITION BY member_id ORDER BY admit_dt, claim_id);

CREATE OR REPLACE TABLE episodes AS
WITH idx AS (
    SELECT member_id, claim_id AS index_claim_id, provider_id, drg, admit_dt, discharge_dt,
           paid AS index_paid,
           discharge_dt + INTERVAL 30 DAY AS window_end
    FROM ip_ordered
    WHERE (prev_discharge_dt IS NULL OR admit_dt > prev_discharge_dt + INTERVAL 30 DAY)
      AND admit_dt BETWEEN DATE '2008-03-01' AND DATE '2009-11-30'
),
readmit AS (
    SELECT i.index_claim_id, count(*) AS n_readmits, sum(r.paid) AS readmit_paid
    FROM idx i
    JOIN ip r ON r.member_id = i.member_id
             AND r.admit_dt > i.discharge_dt
             AND r.admit_dt <= i.window_end
    GROUP BY i.index_claim_id
),
op_w AS (
    SELECT i.index_claim_id, sum(o.paid) AS op_paid
    FROM idx i
    JOIN op o ON o.member_id = i.member_id AND o.service_dt BETWEEN i.admit_dt AND i.window_end
    GROUP BY i.index_claim_id
),
car_w AS (
    SELECT i.index_claim_id, sum(c.paid) AS carrier_paid
    FROM idx i
    JOIN carrier c ON c.member_id = i.member_id AND c.service_dt BETWEEN i.admit_dt AND i.window_end
    GROUP BY i.index_claim_id
)
SELECT
    idx.*,
    coalesce(readmit.n_readmits, 0) > 0     AS readmitted_30d,
    coalesce(readmit.readmit_paid, 0)       AS readmit_paid,
    coalesce(op_w.op_paid, 0)               AS op_paid,
    coalesce(car_w.carrier_paid, 0)         AS carrier_paid,
    idx.index_paid + coalesce(readmit.readmit_paid, 0)
      + coalesce(op_w.op_paid, 0) + coalesce(car_w.carrier_paid, 0) AS episode_paid
FROM idx
LEFT JOIN readmit USING (index_claim_id)
LEFT JOIN op_w    USING (index_claim_id)
LEFT JOIN car_w   USING (index_claim_id);

-- Overall episode summary.
CREATE OR REPLACE TABLE out_episode_summary AS
SELECT
    count(*)                                        AS episodes,
    round(avg(episode_paid))                        AS mean_episode_paid,
    round(median(episode_paid))                     AS median_episode_paid,
    round(100.0 * avg(readmitted_30d::INT), 1)      AS readmit_rate_pct,
    round(100.0 * sum(index_paid)   / sum(episode_paid), 1) AS pct_index_stay,
    round(100.0 * sum(readmit_paid) / sum(episode_paid), 1) AS pct_readmissions,
    round(100.0 * sum(op_paid)      / sum(episode_paid), 1) AS pct_outpatient,
    round(100.0 * sum(carrier_paid) / sum(episode_paid), 1) AS pct_physician
FROM episodes;

-- Top DRGs by episode volume.
CREATE OR REPLACE TABLE out_episodes_by_drg AS
SELECT
    drg,
    count(*)                                   AS episodes,
    round(avg(index_paid))                     AS mean_index_paid,
    round(avg(episode_paid - index_paid))      AS mean_post_index_paid,
    round(avg(episode_paid))                   AS mean_episode_paid,
    round(100.0 * avg(readmitted_30d::INT), 1) AS readmit_rate_pct
FROM episodes
WHERE drg IS NOT NULL
GROUP BY drg
ORDER BY episodes DESC, drg
LIMIT 15;
