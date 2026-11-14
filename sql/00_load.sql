-- Load DE-SynPUF sample 2 CSVs into DuckDB tables with clean types.
-- {RAW} is replaced with the data/raw path by src/02_run_sql.py.

-- Beneficiary summary: one row per member per year (2008-2010).
CREATE OR REPLACE TABLE bene AS
SELECT
    year,
    DESYNPUF_ID                                   AS member_id,
    strptime(BENE_BIRTH_DT::VARCHAR, '%Y%m%d')::DATE AS birth_dt,
    try_strptime(BENE_DEATH_DT::VARCHAR, '%Y%m%d')::DATE AS death_dt,
    BENE_SEX_IDENT_CD                             AS sex,
    SP_STATE_CODE                                 AS state_code,
    BENE_HI_CVRAGE_TOT_MONS                       AS part_a_months,
    BENE_SMI_CVRAGE_TOT_MONS                      AS part_b_months,
    BENE_HMO_CVRAGE_TOT_MONS                      AS hmo_months,
    PLAN_CVRG_MOS_NUM::INTEGER                    AS part_d_months,
    -- Chronic condition flags are coded 1 = yes, 2 = no.
    (SP_ALZHDMTA = 1)::INT + (SP_CHF = 1)::INT + (SP_CHRNKIDN = 1)::INT + (SP_CNCR = 1)::INT
      + (SP_COPD = 1)::INT + (SP_DEPRESSN = 1)::INT + (SP_DIABETES = 1)::INT
      + (SP_ISCHMCHT = 1)::INT + (SP_OSTEOPRS = 1)::INT + (SP_RA_OA = 1)::INT
      + (SP_STRKETIA = 1)::INT                     AS n_chronic,
    SP_CHF = 1                                    AS has_chf,
    SP_DIABETES = 1                               AS has_diabetes,
    MEDREIMB_IP, MEDREIMB_OP, MEDREIMB_CAR        -- summary-file Medicare payments, for reconciliation
FROM (
    SELECT 2008 AS year, * FROM read_csv('{RAW}/DE1_0_2008_Beneficiary_Summary_File_Sample_2.csv', header = true)
    UNION ALL BY NAME
    SELECT 2009 AS year, * FROM read_csv('{RAW}/DE1_0_2009_Beneficiary_Summary_File_Sample_2.csv', header = true)
    UNION ALL BY NAME
    SELECT 2010 AS year, * FROM read_csv('{RAW}/DE1_0_2010_Beneficiary_Summary_File_Sample_2.csv', header = true)
);

-- Inpatient: a long stay can be split into several SEGMENT rows sharing CLM_ID.
-- Collapse to one row per claim; payment = sum over segments.
CREATE OR REPLACE TABLE ip AS
SELECT
    DESYNPUF_ID                                            AS member_id,
    CLM_ID                                                 AS claim_id,
    any_value(PRVDR_NUM ORDER BY SEGMENT)                  AS provider_id,
    min(strptime(coalesce(CLM_ADMSN_DT, CLM_FROM_DT)::VARCHAR, '%Y%m%d'))::DATE AS admit_dt,
    max(strptime(coalesce(NCH_BENE_DSCHRG_DT, CLM_THRU_DT)::VARCHAR, '%Y%m%d'))::DATE AS discharge_dt,
    any_value(CLM_DRG_CD ORDER BY SEGMENT)                 AS drg,
    sum(CLM_PMT_AMT)                                       AS paid
FROM read_csv('{RAW}/DE1_0_2008_to_2010_Inpatient_Claims_Sample_2.csv', header = true, all_varchar = false,
              types = {'CLM_ID': 'VARCHAR', 'PRVDR_NUM': 'VARCHAR', 'CLM_DRG_CD': 'VARCHAR'})
WHERE CLM_FROM_DT IS NOT NULL
GROUP BY ALL;

CREATE OR REPLACE TABLE op AS
SELECT
    DESYNPUF_ID                                            AS member_id,
    CLM_ID                                                 AS claim_id,
    any_value(PRVDR_NUM)                                   AS provider_id,
    min(strptime(CLM_FROM_DT::VARCHAR, '%Y%m%d'))::DATE    AS service_dt,
    sum(CLM_PMT_AMT)                                       AS paid
FROM read_csv('{RAW}/DE1_0_2008_to_2010_Outpatient_Claims_Sample_2.csv', header = true,
              types = {'CLM_ID': 'VARCHAR', 'PRVDR_NUM': 'VARCHAR'})
WHERE CLM_FROM_DT IS NOT NULL
GROUP BY ALL;

-- Carrier (physician / supplier, Part B): up to 13 line items per claim in wide
-- columns; claim payment = sum of the line Medicare payments.
CREATE OR REPLACE TABLE carrier AS
SELECT
    DESYNPUF_ID                                            AS member_id,
    CLM_ID                                                 AS claim_id,
    strptime(CLM_FROM_DT::VARCHAR, '%Y%m%d')::DATE         AS service_dt,
    list_sum(list_value(COLUMNS('^LINE_NCH_PMT_AMT_\d+$'))) AS paid
FROM read_csv(['{RAW}/DE1_0_2008_to_2010_Carrier_Claims_Sample_2A.csv',
               '{RAW}/DE1_0_2008_to_2010_Carrier_Claims_Sample_2B.csv'], header = true,
              types = {'CLM_ID': 'VARCHAR'})
WHERE CLM_FROM_DT IS NOT NULL;

-- Part D prescription drug events. SynPUF has total drug cost and patient pay,
-- not plan payment; drug "cost" below is total cost.
CREATE OR REPLACE TABLE rx AS
SELECT
    DESYNPUF_ID                                            AS member_id,
    strptime(SRVC_DT::VARCHAR, '%Y%m%d')::DATE             AS service_dt,
    TOT_RX_CST_AMT                                         AS total_cost,
    PTNT_PAY_AMT                                           AS patient_paid
FROM read_csv('{RAW}/DE1_0_2008_to_2010_Prescription_Drug_Events_Sample_2.csv', header = true,
              types = {'PDE_ID': 'VARCHAR', 'PROD_SRVC_ID': 'VARCHAR'})
WHERE SRVC_DT IS NOT NULL;

CREATE OR REPLACE TABLE out_load_summary AS
SELECT 'bene (member-years)' AS table_name, count(*) AS n_rows FROM bene
UNION ALL SELECT 'ip (claims)', count(*) FROM ip
UNION ALL SELECT 'op (claims)', count(*) FROM op
UNION ALL SELECT 'carrier (claims)', count(*) FROM carrier
UNION ALL SELECT 'rx (fills)', count(*) FROM rx
ORDER BY table_name;
