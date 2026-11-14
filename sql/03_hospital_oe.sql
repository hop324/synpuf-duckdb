-- Hospital cost vs. peers, adjusted for case mix (observed / expected).
--
-- SynPUF has no provider specialty, so hospitals are compared with what all
-- hospitals are paid for the SAME DRGs:
--   expected cost of an admission = average payment for its DRG across all hospitals
--   O/E ratio for a hospital       = sum(actual payments) / sum(expected payments)
-- O/E = 1.20 means the hospital is paid 20% more than peers would be for the
-- same mix of cases. Rare DRGs (< 20 admissions) and small hospitals (< 30
-- admissions) are left out because their averages are too noisy.
-- Uses admissions in the complete-data window, Mar 2008 - Dec 2009.

CREATE OR REPLACE TABLE ip_window AS
SELECT * FROM ip WHERE admit_dt BETWEEN DATE '2008-03-01' AND DATE '2009-12-31';

CREATE OR REPLACE TABLE drg_norm AS
SELECT drg, count(*) AS n_drg, avg(paid) AS drg_mean_paid
FROM ip_window
WHERE drg IS NOT NULL AND paid > 0
GROUP BY drg
HAVING count(*) >= 20;

CREATE OR REPLACE TABLE hospital_oe AS
SELECT
    i.provider_id,
    count(*)                                   AS admissions,
    count(DISTINCT i.drg)                      AS distinct_drgs,
    sum(i.paid)                                AS observed_paid,
    sum(d.drg_mean_paid)                       AS expected_paid,
    sum(i.paid) / sum(d.drg_mean_paid)         AS oe_ratio,
    avg(i.paid)                                AS raw_cost_per_admission,
    avg(d.drg_mean_paid)                       AS case_mix_index_dollars
FROM ip_window i
JOIN drg_norm d USING (drg)
WHERE i.paid > 0
GROUP BY i.provider_id
HAVING count(*) >= 30;

-- Rank hospitals and show how much case-mix adjustment changes the ranking.
CREATE OR REPLACE TABLE out_hospital_oe AS
SELECT
    provider_id,
    admissions,
    distinct_drgs,
    round(raw_cost_per_admission)   AS raw_cost_per_admission,
    round(case_mix_index_dollars)   AS expected_cost_per_admission,
    round(oe_ratio, 3)              AS oe_ratio,
    rank() OVER (ORDER BY raw_cost_per_admission DESC) AS rank_raw_cost,
    rank() OVER (ORDER BY oe_ratio DESC)               AS rank_oe,
    round(observed_paid - expected_paid)               AS excess_paid_vs_peers
FROM hospital_oe
ORDER BY oe_ratio DESC, provider_id;

CREATE OR REPLACE TABLE out_hospital_oe_summary AS
SELECT
    count(*)                                                AS hospitals,
    sum(admissions)                                         AS admissions_covered,
    round(100.0 * sum(admissions) / (SELECT count(*) FROM ip_window WHERE paid > 0), 1) AS pct_of_all_admissions,
    round(quantile_cont(oe_ratio, 0.10), 3)                 AS oe_p10,
    round(median(oe_ratio), 3)                              AS oe_median,
    round(quantile_cont(oe_ratio, 0.90), 3)                 AS oe_p90,
    round(corr(rank_raw_cost, rank_oe), 3)                  AS rank_corr_raw_vs_oe,
    sum((rank_raw_cost <= 10 AND rank_oe > 10)::INT)        AS raw_top10_not_oe_top10
FROM out_hospital_oe;

-- Is the spread real or noise? Permutation check: shuffle which hospital each
-- admission belongs to (keeping each hospital's admission count), recompute
-- O/E, and compare the 10th-90th percentile spread with the real one. If the
-- shuffled spread is as wide as the real one, hospital differences are mostly
-- chance. 20 shuffles. The "random" order is a hash of (shuffle, claim id), so
-- it is identical on every run (DuckDB's random() is not reproducible across threads).

CREATE OR REPLACE TABLE oe_null_draws AS   -- pseudo-random keys stored as columns
SELECT rep, i.claim_id, i.provider_id, i.paid, d.drg_mean_paid,
       hash(rep, i.claim_id, 'slot') AS r_slot, hash(rep, i.claim_id, 'draw') AS r_draw
FROM ip_window i
JOIN drg_norm d USING (drg)
CROSS JOIN range(20) t(rep)
WHERE i.paid > 0 AND i.provider_id IN (SELECT provider_id FROM hospital_oe);

CREATE OR REPLACE TABLE oe_null AS
WITH shuffled AS (
    SELECT *,
           row_number() OVER (PARTITION BY rep ORDER BY provider_id, r_slot, claim_id) AS slot,
           row_number() OVER (PARTITION BY rep ORDER BY r_draw, claim_id)     AS draw
    FROM oe_null_draws
),
reassigned AS (   -- hospital slots keep their size; admissions are drawn at random
    SELECT a.rep, a.provider_id, b.paid, b.drg_mean_paid
    FROM shuffled a JOIN shuffled b ON a.rep = b.rep AND a.slot = b.draw
),
oe AS (
    SELECT rep, provider_id, sum(paid) / sum(drg_mean_paid) AS oe_ratio
    FROM reassigned GROUP BY ALL
)
SELECT * FROM oe;

CREATE OR REPLACE TABLE out_hospital_oe_shuffled AS   -- every shuffled O/E, for the figure
SELECT rep, provider_id, round(oe_ratio, 4) AS oe_ratio FROM oe_null ORDER BY rep, provider_id;

CREATE OR REPLACE TABLE out_hospital_oe_vs_noise AS
SELECT 'actual hospitals' AS version,
       round(quantile_cont(oe_ratio, 0.10), 3) AS oe_p10,
       round(quantile_cont(oe_ratio, 0.90), 3) AS oe_p90,
       round(quantile_cont(oe_ratio, 0.90) - quantile_cont(oe_ratio, 0.10), 3) AS p90_minus_p10
FROM hospital_oe
UNION ALL
SELECT 'shuffled (mean of 20)', round(avg(p10), 3), round(avg(p90), 3), round(avg(p90 - p10), 3)
FROM (SELECT rep, quantile_cont(oe_ratio, 0.10) AS p10, quantile_cont(oe_ratio, 0.90) AS p90
      FROM oe_null GROUP BY rep)
ORDER BY version;
