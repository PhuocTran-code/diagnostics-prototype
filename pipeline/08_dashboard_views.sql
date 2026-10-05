-- Dashboard views (gold layer only)
-- Owner: B (Phuoc Tran)
-- D1: v_turnaround        — avg / p50 / p90 turnaround by site, priority, request type
-- D2: v_abnormal_rate     — abnormal result rate (pathology) and critical finding rate (imaging)
-- D3: v_mpi_impact        — raw source identifiers vs golden patients, collapse metrics

CREATE SCHEMA IF NOT EXISTS dashboard;

DROP VIEW IF EXISTS dashboard.v_mpi_impact;
DROP VIEW IF EXISTS dashboard.v_abnormal_rate;
DROP VIEW IF EXISTS dashboard.v_turnaround;

-- D1: turnaround time by site, priority, and request type.
-- Imaging turnaround_hours is converted to minutes so both streams share one scale.
CREATE VIEW dashboard.v_turnaround AS
SELECT
    ds.site_code,
    ds.site_name,
    fpr.priority,
    'PATHOLOGY'::TEXT                                                    AS request_type,
    dd.year_number,
    dd.month_number,
    dd.month_name,
    COUNT(*)                                                             AS total_results,
    ROUND(AVG(fpr.turnaround_minutes))                                   AS avg_turnaround_minutes,
    PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY fpr.turnaround_minutes) AS p50_minutes,
    PERCENTILE_CONT(0.9) WITHIN GROUP (ORDER BY fpr.turnaround_minutes) AS p90_minutes
FROM gold.fact_pathology_result fpr
JOIN gold.dim_site ds ON fpr.site_key = ds.site_key
JOIN gold.dim_date dd  ON fpr.date_key  = dd.date_key
WHERE fpr.turnaround_minutes IS NOT NULL
GROUP BY ds.site_code, ds.site_name, fpr.priority,
         dd.year_number, dd.month_number, dd.month_name

UNION ALL

SELECT
    ds.site_code,
    ds.site_name,
    fis.priority,
    'IMAGING'::TEXT                                                      AS request_type,
    dd.year_number,
    dd.month_number,
    dd.month_name,
    COUNT(*)                                                             AS total_results,
    ROUND(AVG(fis.turnaround_hours * 60))                               AS avg_turnaround_minutes,
    PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY fis.turnaround_hours * 60) AS p50_minutes,
    PERCENTILE_CONT(0.9) WITHIN GROUP (ORDER BY fis.turnaround_hours * 60) AS p90_minutes
FROM gold.fact_imaging_study fis
JOIN gold.dim_site ds ON fis.site_key = ds.site_key
JOIN gold.dim_date dd  ON fis.date_key  = dd.date_key
WHERE fis.turnaround_hours IS NOT NULL
GROUP BY ds.site_code, ds.site_name, fis.priority,
         dd.year_number, dd.month_number, dd.month_name;

-- D2: abnormal result rate (pathology) and critical finding rate (imaging)
-- by site, test/procedure code, year, and month.
-- NULL fills are used so both request types share one view schema.
CREATE VIEW dashboard.v_abnormal_rate AS
SELECT
    ds.site_code,
    ds.site_name,
    dt.loinc_code                                                        AS code,
    dt.test_name                                                         AS name,
    'PATHOLOGY'::TEXT                                                    AS request_type,
    dd.year_number,
    dd.month_number,
    dd.month_name,
    COUNT(*)                                                             AS total_results,
    SUM(fpr.is_abnormal::INT)                                            AS abnormal_count,
    ROUND(100.0 * SUM(fpr.is_abnormal::INT) / COUNT(*), 2)              AS abnormal_pct,
    NULL::BIGINT                                                         AS critical_count,
    NULL::NUMERIC                                                        AS critical_pct
FROM gold.fact_pathology_result fpr
JOIN gold.dim_site ds ON fpr.site_key = ds.site_key
JOIN gold.dim_date dd  ON fpr.date_key  = dd.date_key
JOIN gold.dim_test dt  ON fpr.test_key  = dt.test_key
GROUP BY ds.site_code, ds.site_name, dt.loinc_code, dt.test_name,
         dd.year_number, dd.month_number, dd.month_name

UNION ALL

SELECT
    ds.site_code,
    ds.site_name,
    dp.procedure_code                                                    AS code,
    dp.procedure_name                                                    AS name,
    'IMAGING'::TEXT                                                      AS request_type,
    dd.year_number,
    dd.month_number,
    dd.month_name,
    COUNT(*)                                                             AS total_results,
    NULL::BIGINT                                                         AS abnormal_count,
    NULL::NUMERIC                                                        AS abnormal_pct,
    SUM(fis.critical_finding::INT)                                       AS critical_count,
    ROUND(100.0 * SUM(fis.critical_finding::INT) / COUNT(*), 2)         AS critical_pct
FROM gold.fact_imaging_study fis
JOIN gold.dim_site ds       ON fis.site_key       = ds.site_key
JOIN gold.dim_date dd       ON fis.date_key       = dd.date_key
JOIN gold.dim_procedure dp  ON fis.procedure_key  = dp.procedure_key
GROUP BY ds.site_code, ds.site_name, dp.procedure_code, dp.procedure_name,
         dd.year_number, dd.month_number, dd.month_name;

-- D3: MPI impact — how many raw source identifiers collapsed into golden patients.
-- Reads silver layer for source counts and match-basis breakdown alongside gold.dim_patient.
CREATE VIEW dashboard.v_mpi_impact AS
SELECT
    (SELECT COUNT(*) FROM silver.patient_source)                         AS raw_identifiers,
    (SELECT COUNT(*) FROM gold.dim_patient)                              AS golden_patients,
    (SELECT COUNT(*) FROM silver.patient_source)
      - (SELECT COUNT(*) FROM gold.dim_patient)                          AS duplicates_collapsed,
    ROUND(100.0 *
        ((SELECT COUNT(*) FROM silver.patient_source)
          - (SELECT COUNT(*) FROM gold.dim_patient))
        / NULLIF((SELECT COUNT(*) FROM silver.patient_source), 0), 2)   AS collapse_rate_pct,
    (SELECT COUNT(*) FROM silver.patient_xref
     WHERE match_basis = 'medicare+dob')                                 AS matched_tier1,
    (SELECT COUNT(*) FROM silver.patient_xref
     WHERE match_basis = 'name+dob+sex')                                 AS matched_tier2,
    (SELECT COUNT(*) FROM silver.patient_xref
     WHERE match_basis = 'unmatched (single source)')                    AS unmatched;

SELECT 'dashboard views created: v_turnaround, v_abnormal_rate, v_mpi_impact' AS status;
