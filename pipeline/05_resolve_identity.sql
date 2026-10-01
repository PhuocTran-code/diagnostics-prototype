-- ============================================================
-- 05_resolve_identity.sql
-- Master patient index (MPI) in SQL: silver.patient_source -> silver.patient + silver.patient_xref
-- Owner: A (Junseog Lee) 2026-10-01   
-- Target: PostgreSQL 15
--
-- Maps to solution design
--   A1 Recommendation R1 (enterprise MPI), scaled down to deterministic rules.
--   Architecture Figure 3 "identity resolution" layer. Output tables are the
--   silver.patient + silver.patient_xref, the single interface gold reads from.
--
-- Matching rules (tier order)
--   Tier 1  Medicare number + date of birth           -> basis 'medicare+dob'
--   Tier 2  Surname + first given name + DOB + sex    -> basis 'name+dob+sex'
--           (records WITHOUT a Medicare number; joins an existing tier 1
--           cluster if exactly one cluster shares the demographic key)
--   Tier 0  No link                                   -> basis 'unmatched (single source)'
--   Two different Medicare numbers are never merged on demographics alone.
--
-- Survivorship for the golden record: first non-null value by source priority
--   lis_b (typed dates, standard codes) > ris > lis_a (legacy, text dates)
--
-- Idempotent full rebuild. Prerequisite: 04_build_silver.sql
-- ============================================================

BEGIN;

TRUNCATE TABLE silver.patient_xref, silver.patient RESTART IDENTITY CASCADE;

-- 1. Comparable keys per source record -------------------------------------
DROP TABLE IF EXISTS tmp_mpi;
CREATE TEMP TABLE tmp_mpi AS
SELECT ps.patient_source_key,
       ps.source_system,
       ps.medicare_no,
       ps.family_name,
       ps.given_name,
       ps.dob,
       ps.sex_code,
       ps.postcode,
       CASE ps.source_system WHEN 'lis_b' THEN 1 WHEN 'ris' THEN 2 WHEN 'lis_a' THEN 3 ELSE 9 END AS src_priority,
       CASE WHEN ps.medicare_no IS NOT NULL AND ps.dob IS NOT NULL
            THEN 'MC:' || ps.medicare_no || '|' || ps.dob::TEXT END                    AS tier1_key,
       CASE WHEN ps.family_name IS NOT NULL AND ps.given_name IS NOT NULL AND ps.dob IS NOT NULL
            THEN 'DM:' || ps.family_name || '|' || SPLIT_PART(ps.given_name,' ',1)
                 || '|' || ps.dob::TEXT || '|' || ps.sex_code END                      AS demo_key
FROM silver.patient_source ps;

-- 2. Assign one cluster_key per record ----------------------------------------
--    tier 1: cluster = tier1_key
--    tier 2: cluster = the single tier-1 cluster sharing demo_key, else demo_key itself
--    tier 0: cluster = own record
DROP TABLE IF EXISTS tmp_cluster;
CREATE TEMP TABLE tmp_cluster AS
WITH t1_demo AS (                     -- demographic keys that map to exactly one tier-1 cluster
  SELECT demo_key, MIN(tier1_key) AS tier1_key
  FROM tmp_mpi WHERE tier1_key IS NOT NULL AND demo_key IS NOT NULL
  GROUP BY demo_key HAVING COUNT(DISTINCT tier1_key) = 1
)
SELECT m.patient_source_key,
       COALESCE(m.tier1_key, d.tier1_key, m.demo_key, 'ONE:' || m.patient_source_key::TEXT) AS cluster_key,
       CASE WHEN m.tier1_key IS NOT NULL THEN 1
            WHEN d.tier1_key IS NOT NULL OR m.demo_key IS NOT NULL THEN 2
            ELSE 0 END AS match_tier
FROM tmp_mpi m
LEFT JOIN t1_demo d ON m.tier1_key IS NULL AND d.demo_key = m.demo_key;

-- 3. Golden record per cluster (survivorship by source priority) -------------
DROP TABLE IF EXISTS tmp_golden;
CREATE TEMP TABLE tmp_golden AS
SELECT c.cluster_key,
       gen_random_uuid() AS golden_id,
       (ARRAY_AGG(m.family_name ORDER BY m.src_priority) FILTER (WHERE m.family_name IS NOT NULL))[1] AS family_name,
       (ARRAY_AGG(m.given_name  ORDER BY m.src_priority) FILTER (WHERE m.given_name  IS NOT NULL))[1] AS given_name,
       (ARRAY_AGG(m.dob         ORDER BY m.src_priority) FILTER (WHERE m.dob         IS NOT NULL))[1] AS dob,
       COALESCE((ARRAY_AGG(m.sex_code ORDER BY m.src_priority) FILTER (WHERE m.sex_code <> 'U'))[1], 'U') AS sex_code,
       (ARRAY_AGG(m.postcode    ORDER BY m.src_priority) FILTER (WHERE m.postcode    IS NOT NULL))[1] AS postcode,
       COUNT(*) AS source_record_count
FROM tmp_cluster c
JOIN tmp_mpi m USING (patient_source_key)
GROUP BY c.cluster_key;

INSERT INTO silver.patient (golden_id, family_name, given_name, dob, sex_code, postcode)
SELECT golden_id, family_name, given_name, dob, sex_code, postcode
FROM tmp_golden
ORDER BY cluster_key;

-- 4. Crosswalk: every source record -> one golden patient ----------------------
INSERT INTO silver.patient_xref (patient_source_key, patient_key, match_basis)
SELECT c.patient_source_key,
       p.patient_key,
       CASE WHEN g.source_record_count = 1 THEN 'unmatched (single source)'
            WHEN c.match_tier = 1          THEN 'medicare+dob'
            ELSE 'name+dob+sex' END
FROM tmp_cluster c
JOIN tmp_golden g ON g.cluster_key = c.cluster_key
JOIN silver.patient p ON p.golden_id = g.golden_id;

-- 5. Audit --------------------------------------------------------------------
INSERT INTO audit.pipeline_run (layer, source_name, target_table, rows_read, rows_loaded, run_status, started_at, completed_at)
VALUES ('identity', 'silver', 'silver.patient_xref',
        (SELECT COUNT(*) FROM silver.patient_source), (SELECT COUNT(*) FROM silver.patient_xref),
        'SUCCESS', NOW(), NOW());

COMMIT;

-- Headline MPI metric (same as V4 in 01_source_schemas.sql)
SELECT (SELECT COUNT(*) FROM silver.patient_source)                  AS raw_identifiers,
       (SELECT COUNT(DISTINCT patient_key) FROM silver.patient_xref) AS golden_patients,
       (SELECT COUNT(*) FROM silver.patient_source)
         - (SELECT COUNT(DISTINCT patient_key) FROM silver.patient_xref) AS duplicates_resolved;
