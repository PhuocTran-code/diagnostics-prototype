-- MPI validation: xref completeness, golden patient counts
-- Owner: B (Phuoc Tran)
--
-- Checks (all columns in the first query should be 0 for a healthy pipeline):
--   unresolved_source_records  — every patient_source row has an xref entry
--   dangling_xref_rows         — every xref row points to a valid silver.patient
--   split_medicare_numbers     — no Medicare number appears under two golden patients
--   silver_gold_discrepancy    — silver golden count matches gold.dim_patient count

SELECT
    (SELECT COUNT(*)
     FROM silver.patient_source ps
     LEFT JOIN silver.patient_xref x
           ON ps.patient_source_key = x.patient_source_key
     WHERE x.patient_source_key IS NULL)                                AS unresolved_source_records,

    (SELECT COUNT(*)
     FROM silver.patient_xref x
     LEFT JOIN silver.patient p ON x.patient_key = p.patient_key
     WHERE p.patient_key IS NULL)                                       AS dangling_xref_rows,

    (SELECT COUNT(*) FROM (
         SELECT ps.medicare_no
         FROM silver.patient_source ps
         JOIN silver.patient_xref x
              ON ps.patient_source_key = x.patient_source_key
         WHERE ps.medicare_no IS NOT NULL
         GROUP BY ps.medicare_no
         HAVING COUNT(DISTINCT x.patient_key) > 1
     ) mc)                                                              AS split_medicare_numbers,

    ABS(
        (SELECT COUNT(DISTINCT patient_key) FROM silver.patient_xref)
        - (SELECT COUNT(*) FROM gold.dim_patient)
    )                                                                   AS silver_gold_discrepancy;

-- Match-basis distribution: shows how many records were resolved by each tier.
-- This is the last SELECT so run_pipeline.py prints it to the console.
SELECT
    match_basis,
    COUNT(*)                                                            AS source_records,
    ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 1)                 AS pct
FROM silver.patient_xref
GROUP BY match_basis
ORDER BY source_records DESC;
