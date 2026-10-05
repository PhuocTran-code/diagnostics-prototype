-- Bronze -> Silver row-count reconciliation and silver data-quality checks
-- Owner: E (Zeming Liu)
--
-- Q1: data-quality domain checks — all columns should be 0
-- Q2: row-count reconciliation per source table (last SELECT, printed by run_pipeline.py)
--     status: OK = no loss, LOSS = rows dropped (explain!), GAIN = unexpected extra rows

-- Q1: silver domain checks — all six columns should be 0 for a clean load
SELECT
    (SELECT COUNT(*) FROM silver.diagnostic_request
     WHERE priority NOT IN ('ROUTINE', 'URGENT'))                        AS bad_priority_values,

    (SELECT COUNT(*) FROM silver.diagnostic_request
     WHERE status NOT IN ('IN_PROGRESS', 'FINAL', 'CANCELLED'))          AS bad_status_values,

    (SELECT COUNT(*) FROM silver.patient_source
     WHERE sex_code NOT IN ('M', 'F', 'U'))                              AS bad_sex_codes,

    (SELECT COUNT(*) FROM silver.pathology_result
     WHERE abnormal_flag NOT IN ('N', 'L', 'H'))                         AS bad_abnormal_flags,

    (SELECT COUNT(*) FROM silver.diagnostic_request
     WHERE status = 'FINAL' AND collected_at IS NULL)                    AS final_requests_without_date,

    (SELECT COUNT(*) FROM silver.diagnostic_request dr
     LEFT JOIN silver.patient_source ps
            ON dr.patient_source_key = ps.patient_source_key
     WHERE ps.patient_source_key IS NULL)                                AS requests_without_patient;

-- Q2: Bronze -> Silver row-count reconciliation (9 source tables -> 4 silver tables)
SELECT
    source_table,
    bronze_rows,
    silver_rows,
    bronze_rows - silver_rows                                            AS dropped,
    CASE
        WHEN bronze_rows = silver_rows THEN 'OK'
        WHEN bronze_rows > silver_rows THEN 'LOSS'
        ELSE 'GAIN'
    END                                                                  AS status
FROM (
    SELECT 'lis_a patients'   AS source_table,
           (SELECT COUNT(*) FROM bronze.lis_a_patient)                           AS bronze_rows,
           (SELECT COUNT(*) FROM silver.patient_source
            WHERE source_system = 'lis_a')                                       AS silver_rows
    UNION ALL
    SELECT 'lis_b patients',
           (SELECT COUNT(*) FROM bronze.lis_b_patients),
           (SELECT COUNT(*) FROM silver.patient_source
            WHERE source_system = 'lis_b')
    UNION ALL
    SELECT 'ris patients',
           (SELECT COUNT(*) FROM bronze.ris_patient),
           (SELECT COUNT(*) FROM silver.patient_source
            WHERE source_system = 'ris')
    UNION ALL
    SELECT 'lis_a requests',
           (SELECT COUNT(*) FROM bronze.lis_a_request),
           (SELECT COUNT(*) FROM silver.diagnostic_request
            WHERE source_system = 'lis_a')
    UNION ALL
    SELECT 'lis_b episodes',
           (SELECT COUNT(*) FROM bronze.lis_b_episodes),
           (SELECT COUNT(*) FROM silver.diagnostic_request
            WHERE source_system = 'lis_b')
    UNION ALL
    SELECT 'ris exam orders',
           (SELECT COUNT(*) FROM bronze.ris_exam_order),
           (SELECT COUNT(*) FROM silver.diagnostic_request
            WHERE source_system = 'ris')
    UNION ALL
    SELECT 'lis_a results',
           (SELECT COUNT(*) FROM bronze.lis_a_result),
           (SELECT COUNT(*) FROM silver.pathology_result pr
            JOIN silver.diagnostic_request dr ON pr.request_id = dr.request_id
            WHERE dr.source_system = 'lis_a')
    UNION ALL
    SELECT 'lis_b observations',
           (SELECT COUNT(*) FROM bronze.lis_b_observations),
           (SELECT COUNT(*) FROM silver.pathology_result pr
            JOIN silver.diagnostic_request dr ON pr.request_id = dr.request_id
            WHERE dr.source_system = 'lis_b')
    UNION ALL
    SELECT 'ris reports',
           (SELECT COUNT(*) FROM bronze.ris_report),
           (SELECT COUNT(*) FROM silver.imaging_report)
) t
ORDER BY source_table;
