-- ============================================================
-- 02_synthetic_data.sql
-- Synthetic source data for the three operational systems (section 3.1 / 3.3)
-- Owner: A (Junseog Lee) 2026-10-01
-- Target: PostgreSQL 15. Pure SQL, deterministic (setseed), re-runnable.
--
-- Approach: build a ground-truth list of PERSONS first, then project each person into
-- the systems they "visited" using that system's own conventions (id format, date format,
-- name case, sex coding). The truth table is kept in audit.synthetic_person so the
-- identity-resolution step can be scored against it (tests/validate_mpi.sql).
--
-- Population (61 persons, cases chosen to exercise every MPI rule)
--   P01-P25  in 2 or 3 systems, Medicare present everywhere         -> tier 1 (Medicare + DOB)
--   P26-P29  in lis_a + lis_b, Medicare missing in lis_b              -> tier 2 joins a tier-1 record
--   P30-P33  in lis_a + ris,  Medicare missing in BOTH                -> tier 2 only (name + DOB + sex)
--   P34-P57  one system only (lis_a 12, lis_b 6, ris 6), some with no Medicare -> unmatched
--   P58/P59, P60/P61  two look-alike pairs: same name, DOB and sex, DIFFERENT Medicare
--                     -> must stay two people (tests the "never merge on demographics alone" rule)
--   plus the two hand-written patients from 01_source_schemas.sql (NGUYEN MINH THI, TRAN VAN DUC)
--
-- Activity window: 2025-01-01 .. 2025-06-30
--   lis_a  2-6 requests per patient, 2-4 analytes each   (text dates, local test codes)
--   lis_b  2-5 episodes per patient, 2-4 observations    (UTC timestamps, LOINC)
--   ris    1-3 orders per patient, one report per completed order
--   priority 15% urgent; status ~85% final / 10% in progress / 5% cancelled
--   ~20% abnormal analytes; ~5% critical imaging findings
--
-- Prerequisite: 01_source_schemas.sql (schemas, tables, base test_code_map rows)
-- ============================================================

SELECT setseed(0.42);

-- ------------------------------------------------------------
-- 0. Helpers (session-local, in pg_temp)
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION pg_temp.rint(lo INT, hi INT) RETURNS INT
LANGUAGE sql VOLATILE AS $$ SELECT lo + FLOOR(random() * (hi - lo + 1))::INT $$;

CREATE OR REPLACE FUNCTION pg_temp.pick(arr TEXT[]) RETURNS TEXT
LANGUAGE sql VOLATILE AS $$ SELECT arr[1 + FLOOR(random() * array_length(arr, 1))::INT] $$;

CREATE OR REPLACE FUNCTION pg_temp.rts(d0 DATE, d1 DATE) RETURNS TIMESTAMP    -- random working-hours timestamp
LANGUAGE sql VOLATILE AS $$
  SELECT (d0 + FLOOR(random() * (d1 - d0 + 1))::INT)::TIMESTAMP
         + MAKE_INTERVAL(hours => 7 + FLOOR(random() * 11)::INT, mins => FLOOR(random() * 60)::INT)
$$;

-- ------------------------------------------------------------
-- 1. Remove previously generated rows (keeps the hand-written samples from 01)
-- ------------------------------------------------------------
DELETE FROM lis_a.result  WHERE req_no LIKE '25R%';
DELETE FROM lis_a.request WHERE req_no LIKE '25R%';
DELETE FROM lis_a.patient WHERE pat_no LIKE 'P1%';
DELETE FROM lis_b.observations WHERE episode_id IN (SELECT episode_id FROM lis_b.episodes WHERE accession_number LIKE 'LB25-%');
DELETE FROM lis_b.episodes WHERE accession_number LIKE 'LB25-%';
DELETE FROM lis_b.patients WHERE patient_guid IN (SELECT MD5('lisb' || n)::UUID FROM GENERATE_SERIES(1, 200) n);
DELETE FROM ris.report     WHERE accession_number LIKE 'RIS25-%';
DELETE FROM ris.exam_order WHERE accession_number LIKE 'RIS25-%';
DELETE FROM ris.patient    WHERE ris_patient_id >= 90100;

-- ------------------------------------------------------------
-- 2. Reference data: tests, procedures, sites, referrers
-- ------------------------------------------------------------
DROP TABLE IF EXISTS gen_test;
CREATE TEMP TABLE gen_test (local_code TEXT, loinc TEXT, test_name TEXT, unit TEXT, lo NUMERIC, hi NUMERIC);
INSERT INTO gen_test VALUES
 ('HB',   '718-7',   'Haemoglobin',        'g/L',     115, 165),
 ('WBC',  '6690-2',  'White cell count',   '10*9/L',  4.0, 11.0),
 ('PLT',  '777-3',   'Platelet count',     '10*9/L',  150, 400),
 ('GLUC', '15074-8', 'Glucose (fasting)',  'mmol/L',  3.5, 6.0),
 ('CHOL', '2093-3',  'Cholesterol total',  'mmol/L',  2.5, 5.5),
 ('TSH',  '3016-3',  'TSH',                'mIU/L',   0.4, 4.0),
 ('CREAT','2160-0',  'Creatinine',         'umol/L',  45,  110),
 ('ALT',  '1742-6',  'ALT',                'U/L',     5,   40),
 ('NA',   '2951-2',  'Sodium',             'mmol/L',  135, 145),
 ('K',    '2823-3',  'Potassium',          'mmol/L',  3.5, 5.2);

DROP TABLE IF EXISTS gen_proc;
CREATE TEMP TABLE gen_proc (procedure_code TEXT, modality TEXT, procedure_name TEXT, normal_text TEXT, critical_text TEXT);
INSERT INTO gen_proc VALUES
 ('XRCHEST','CR','Chest X-ray',          'Chest X-ray: lungs clear, heart size normal.',      'Chest X-ray: large right pneumothorax. Urgent clinical review.'),
 ('CTABDO', 'CT','CT abdomen',           'CT abdomen: no focal lesion.',                      'CT abdomen: free intraperitoneal gas. Urgent surgical review.'),
 ('CTHEAD', 'CT','CT head',              'CT head: no acute intracranial abnormality.',       'CT head: acute subdural haematoma with midline shift.'),
 ('MRKNEE', 'MR','MRI knee',             'MRI knee: intact ligaments, mild effusion.',        'MRI knee: complete ACL rupture with bone bruise.'),
 ('USABDO', 'US','Ultrasound abdomen',   'Ultrasound abdomen: normal liver and gallbladder.', 'Ultrasound abdomen: dilated common bile duct, obstruction likely.'),
 ('XRSPINE','CR','Lumbar spine X-ray',   'Lumbar spine: mild degenerative change.',           'Lumbar spine: acute compression fracture L1.');

-- Terminology map rows for the new codes (01 already has HB, GLUC, 718-7, 1742-6, CTABDO, XRCHEST)
INSERT INTO silver.test_code_map (source_system, source_code, loinc_code, test_name, modality)
SELECT 'lis_a', local_code, loinc, test_name, NULL FROM gen_test
UNION ALL
SELECT 'lis_b', loinc, loinc, test_name, NULL FROM gen_test
UNION ALL
SELECT 'ris', procedure_code, NULL, procedure_name, modality FROM gen_proc
ON CONFLICT (source_system, source_code) DO NOTHING;

-- ------------------------------------------------------------
-- 3. Ground truth: persons
-- ------------------------------------------------------------
DROP TABLE IF EXISTS gen_person;
CREATE TEMP TABLE gen_person AS
WITH names AS (
  SELECT ARRAY['NGUYEN','TRAN','LE','PHAM','SMITH','JONES','WILLIAMS','BROWN','WILSON','TAYLOR',
               'CHEN','WANG','LI','ZHANG','KIM','PARK','PATEL','SINGH','MARTIN','THOMPSON'] AS sur,
         ARRAY['JAMES','JOHN','MICHAEL','DAVID','MINH','DUC','WEI','JUN','RAJ','LIAM','THOMAS','HUY'] AS male,
         ARRAY['MARY','SARAH','EMMA','ANNA','LINH','THI','MEI','JI','PRIYA','OLIVIA','CHLOE','HOA'] AS female,
         ARRAY['VAN','THI','ANN','LEE','MAY','JAMES','ROSE','HUU'] AS middle
)
SELECT n AS person_id,
       pg_temp.pick(sur) AS surname,
       CASE WHEN sex = 'M' THEN pg_temp.pick(male) ELSE pg_temp.pick(female) END AS given1,
       CASE WHEN random() < 0.5 THEN pg_temp.pick(middle) END AS given2,
       (DATE '1940-01-01' + FLOOR(random() * 25000)::INT) AS dob,
       sex,
       (2000 + FLOOR(random() * 300)::INT)::TEXT AS postcode,
       (3000000000::BIGINT + n * 100000 + FLOOR(random() * 99999)::INT)::TEXT AS medicare,
       CASE WHEN n BETWEEN 1  AND 10 THEN 'T1 all three'
            WHEN n BETWEEN 11 AND 18 THEN 'T1 lis_a+lis_b'
            WHEN n BETWEEN 19 AND 25 THEN 'T1 lis_a+ris'
            WHEN n BETWEEN 26 AND 29 THEN 'T2 lis_a+lis_b (lis_b no medicare)'
            WHEN n BETWEEN 30 AND 33 THEN 'T2 lis_a+ris (no medicare)'
            WHEN n BETWEEN 34 AND 45 THEN 'single lis_a'
            WHEN n BETWEEN 46 AND 51 THEN 'single lis_b'
            WHEN n BETWEEN 52 AND 57 THEN 'single ris'
            WHEN n IN (58, 59)       THEN 'lookalike pair A'
            ELSE                          'lookalike pair B' END AS case_type,
       -- which systems hold a record for this person
       (n <= 45 OR n IN (58, 60))                                  AS in_lis_a,
       (n <= 18 OR n BETWEEN 26 AND 29 OR n BETWEEN 46 AND 51 OR n IN (59, 61)) AS in_lis_b,
       (n <= 10 OR n BETWEEN 19 AND 25 OR n BETWEEN 30 AND 33 OR n BETWEEN 52 AND 57) AS in_ris,
       -- medicare known in each system
       (n NOT BETWEEN 30 AND 33 AND NOT (n BETWEEN 34 AND 57 AND random() < 0.25)) AS mc_lis_a,
       (n NOT BETWEEN 26 AND 33)                                   AS mc_lis_b,
       (n NOT BETWEEN 30 AND 33 AND NOT (n BETWEEN 52 AND 57 AND random() < 0.25)) AS mc_ris
FROM names, GENERATE_SERIES(1, 61) AS n,
     LATERAL (SELECT CASE WHEN random() < 0.5 THEN 'M' ELSE 'F' END AS sex) s;

-- look-alike pairs: second person copies name, DOB, sex of the first; Medicare stays different
UPDATE gen_person b SET surname = a.surname, given1 = a.given1, dob = a.dob, sex = a.sex
FROM gen_person a WHERE (a.person_id, b.person_id) IN ((58, 59), (60, 61));
-- make the pairs' records unambiguous tier-1 clusters with different Medicare: already true (medicare includes person_id)

-- persist ground truth for validation
DROP TABLE IF EXISTS audit.synthetic_person;
CREATE TABLE audit.synthetic_person AS
SELECT person_id, case_type, in_lis_a, in_lis_b, in_ris,
       (in_lis_a::INT + in_lis_b::INT + in_ris::INT) AS system_count,
       surname, given1, dob, sex, medicare
FROM gen_person;
COMMENT ON TABLE audit.synthetic_person IS 'Ground truth for the synthetic population: one row per real person. Used to score identity resolution.';

-- ------------------------------------------------------------
-- 4. Patients, projected into each system's conventions
-- ------------------------------------------------------------
-- lis_a: upper case, given names in one field, DOB as DD/MM/YYYY text, M/F
INSERT INTO lis_a.patient (pat_no, medicare_no, surname, given_names, dob, sex, postcode)
SELECT 'P1' || LPAD(person_id::TEXT, 5, '0'),
       CASE WHEN mc_lis_a THEN medicare ELSE '' END,
       surname,
       given1 || COALESCE(' ' || given2, ''),
       TO_CHAR(dob, 'DD/MM/YYYY'),
       sex,
       CASE WHEN random() < 0.2 THEN (2000 + FLOOR(random() * 300)::INT)::TEXT ELSE postcode END   -- 20% moved house
FROM gen_person WHERE in_lis_a;

-- lis_b: UUID key, mixed case, single given name, typed DATE, male/female
INSERT INTO lis_b.patients (patient_guid, medicare_number, family_name, given_name, birth_date, administrative_sex, postcode)
SELECT MD5('lisb' || person_id)::UUID,
       CASE WHEN mc_lis_b THEN medicare ELSE NULL END,
       INITCAP(LOWER(surname)),
       INITCAP(LOWER(given1)),
       dob,
       CASE sex WHEN 'M' THEN 'male' ELSE 'female' END,
       postcode
FROM gen_person WHERE in_lis_b;

-- ris: integer key, upper case, typed DATE, M/F
INSERT INTO ris.patient (ris_patient_id, medicare_no, last_name, first_name, date_of_birth, gender, postcode)
SELECT 90100 + person_id,
       CASE WHEN mc_ris THEN medicare ELSE '' END,
       surname, given1, dob, sex, postcode
FROM gen_person WHERE in_ris;

-- ------------------------------------------------------------
-- 5. lis_a requests and results
-- ------------------------------------------------------------
DROP TABLE IF EXISTS gen_req_a;
CREATE TEMP TABLE gen_req_a AS
SELECT '25R' || LPAD((ROW_NUMBER() OVER ())::TEXT, 7, '0') AS req_no,
       p.pat_no,
       pg_temp.pick(ARRAY['2451371X','2451382Y','2451393W','2451404K','2451415J','2451426H','2451437F','2451448T',
                          '2451459L','2451460A','2451471B','2451482C','2451493D','2451504E','2451515G']) AS ref_doctor_code,
       pg_temp.pick(ARRAY['CC001','CC002','CC003','CC004','CC005','CC012']) AS site_code,
       pg_temp.rts(DATE '2025-01-01', DATE '2025-06-30') AS coll_ts,
       CASE WHEN random() < 0.15 THEN 'U' ELSE 'R' END AS priority,
       CASE WHEN r < 0.85 THEN 'FN' WHEN r < 0.95 THEN 'IP' ELSE 'CN' END AS status
FROM lis_a.patient p
CROSS JOIN LATERAL GENERATE_SERIES(1, pg_temp.rint(2, 6) + (LENGTH(p.pat_no) - LENGTH(p.pat_no))) g
CROSS JOIN LATERAL (SELECT random() AS r WHERE p.pat_no IS NOT NULL) x
WHERE p.pat_no LIKE 'P1%';

INSERT INTO lis_a.request (req_no, pat_no, ref_doctor_code, site_code, coll_dt, priority, status)
SELECT req_no, pat_no, ref_doctor_code, site_code, TO_CHAR(coll_ts, 'DD/MM/YYYY HH24:MI:SS'), priority, status
FROM gen_req_a;

INSERT INTO lis_a.result (result_id, req_no, test_code, test_name, result_value, unit, abn_flag, verified_dt)
SELECT 100000 + ROW_NUMBER() OVER (),
       r.req_no,
       t.local_code,
       t.test_name,
       v.val::TEXT,
       t.unit,
       CASE WHEN v.val < t.lo THEN 'L' WHEN v.val > t.hi THEN 'H' ELSE ' ' END,
       TO_CHAR(r.coll_ts + CASE WHEN r.priority = 'U'
                                THEN MAKE_INTERVAL(mins => pg_temp.rint(30, 120))
                                ELSE MAKE_INTERVAL(mins => pg_temp.rint(120, 480)) END,
               'DD/MM/YYYY HH24:MI:SS')
FROM gen_req_a r
CROSS JOIN LATERAL (SELECT * FROM gen_test WHERE r.req_no IS NOT NULL ORDER BY random() LIMIT pg_temp.rint(2, 4)) t
CROSS JOIN LATERAL (SELECT ROUND((CASE WHEN random() < 0.2
                                      THEN CASE WHEN random() < 0.5 THEN t.lo * (0.7 + random() * 0.25) ELSE t.hi * (1.05 + random() * 0.3) END
                                      ELSE t.lo + random() * (t.hi - t.lo) END)::NUMERIC, 1) AS val) v
WHERE r.status = 'FN';

-- ------------------------------------------------------------
-- 6. lis_b episodes and observations
-- ------------------------------------------------------------
DROP TABLE IF EXISTS gen_ep_b;
CREATE TEMP TABLE gen_ep_b AS
SELECT MD5('ep' || ROW_NUMBER() OVER () || p.patient_guid::TEXT)::UUID AS episode_id,
       p.patient_guid,
       'LB25-' || LPAD((ROW_NUMBER() OVER ())::TEXT, 6, '0') AS accession_number,
       pg_temp.pick(ARRAY['2451371X','2451382Y','2451393W','2451404K','2451415J','2451426H','2451437F','2451448T',
                          '2451459L','2451460A','2451471B','2451482C','2451493D','2451504E','2451515G']) AS ordering_provider,
       pg_temp.pick(ARRAY['SITE01','SITE02','SITE03','SITE04','SITE07']) AS site_code,
       pg_temp.rts(DATE '2025-01-01', DATE '2025-06-30') AS coll_local,
       CASE WHEN random() < 0.15 THEN 'urgent' ELSE 'routine' END AS urgency,
       CASE WHEN r < 0.85 THEN 'final' WHEN r < 0.95 THEN 'in_progress' ELSE 'cancelled' END AS episode_status
FROM lis_b.patients p
CROSS JOIN LATERAL GENERATE_SERIES(1, pg_temp.rint(2, 5) + (LENGTH(p.patient_guid::TEXT) - LENGTH(p.patient_guid::TEXT))) g
CROSS JOIN LATERAL (SELECT random() AS r WHERE p.patient_guid IS NOT NULL) x
WHERE p.patient_guid IN (SELECT MD5('lisb' || n)::UUID FROM GENERATE_SERIES(1, 200) n);

INSERT INTO lis_b.episodes (episode_id, patient_guid, accession_number, ordering_provider, site_code, collected_utc, urgency, episode_status)
SELECT episode_id, patient_guid, accession_number, ordering_provider, site_code,
       coll_local AT TIME ZONE 'Australia/Sydney',          -- stored as UTC instant
       urgency, episode_status
FROM gen_ep_b;

INSERT INTO lis_b.observations (observation_id, episode_id, loinc_code, analyte_name, value_numeric, ucum_unit, interpretation, reported_utc)
SELECT 200000 + ROW_NUMBER() OVER (),
       e.episode_id,
       t.loinc,
       t.test_name,
       v.val,
       t.unit,
       CASE WHEN v.val < t.lo THEN 'L' WHEN v.val > t.hi THEN 'H' ELSE 'N' END,
       (e.coll_local + CASE WHEN e.urgency = 'urgent'
                            THEN MAKE_INTERVAL(mins => pg_temp.rint(30, 120))
                            ELSE MAKE_INTERVAL(mins => pg_temp.rint(120, 480)) END) AT TIME ZONE 'Australia/Sydney'
FROM gen_ep_b e
CROSS JOIN LATERAL (SELECT * FROM gen_test WHERE e.accession_number IS NOT NULL ORDER BY random() LIMIT pg_temp.rint(2, 4)) t
CROSS JOIN LATERAL (SELECT ROUND((CASE WHEN random() < 0.2
                                      THEN CASE WHEN random() < 0.5 THEN t.lo * (0.7 + random() * 0.25) ELSE t.hi * (1.05 + random() * 0.3) END
                                      ELSE t.lo + random() * (t.hi - t.lo) END)::NUMERIC, 1) AS val) v
WHERE e.episode_status = 'final';

-- ------------------------------------------------------------
-- 7. ris orders and reports
-- ------------------------------------------------------------
DROP TABLE IF EXISTS gen_ord_r;
CREATE TEMP TABLE gen_ord_r AS
SELECT 'RIS25-' || LPAD((ROW_NUMBER() OVER ())::TEXT, 6, '0') AS accession_number,
       p.ris_patient_id,
       pg_temp.pick(ARRAY['2451371X','2451382Y','2451393W','2451404K','2451415J','2451426H','2451437F','2451448T',
                          '2451459L','2451460A','2451471B','2451482C','2451493D','2451504E','2451515G']) AS referrer_code,
       pg_temp.pick(ARRAY['SITE01','SITE02','SITE03','SITE07']) AS site_code,
       pr.procedure_code, pr.modality, pr.normal_text, pr.critical_text,
       pg_temp.rts(DATE '2025-01-01', DATE '2025-06-30') AS order_ts,
       CASE WHEN random() < 0.15 THEN 'URGENT' ELSE 'ROUTINE' END AS priority,
       CASE WHEN r < 0.85 THEN 'COMPLETED' WHEN r < 0.95 THEN 'SCHEDULED' ELSE 'CANCELLED' END AS order_status
FROM ris.patient p
CROSS JOIN LATERAL GENERATE_SERIES(1, pg_temp.rint(1, 3) + (p.ris_patient_id - p.ris_patient_id)) g
CROSS JOIN LATERAL (SELECT * FROM gen_proc WHERE p.ris_patient_id IS NOT NULL ORDER BY random() LIMIT 1) pr
CROSS JOIN LATERAL (SELECT random() AS r WHERE p.ris_patient_id IS NOT NULL) x
WHERE p.ris_patient_id >= 90100;

INSERT INTO ris.exam_order (accession_number, ris_patient_id, referrer_code, site_code, procedure_code, modality, order_datetime, priority, order_status)
SELECT accession_number, ris_patient_id, referrer_code, site_code, procedure_code, modality, order_ts, priority, order_status
FROM gen_ord_r;

INSERT INTO ris.report (report_id, accession_number, radiologist_code, performed_at, verified_at, report_status, critical_finding, report_text)
SELECT 90000 + ROW_NUMBER() OVER (),
       o.accession_number,
       pg_temp.pick(ARRAY['RAD01','RAD02','RAD03','RAD04','RAD05']),
       t.performed_at,
       t.performed_at + MAKE_INTERVAL(hours => CASE WHEN o.priority = 'URGENT' THEN pg_temp.rint(1, 4) ELSE pg_temp.rint(4, 48) END),
       CASE WHEN random() < 0.9 THEN 'FINAL' ELSE 'PRELIM' END,
       c.critical,
       CASE WHEN c.critical THEN o.critical_text ELSE o.normal_text END
FROM gen_ord_r o
CROSS JOIN LATERAL (SELECT o.order_ts + MAKE_INTERVAL(hours => CASE WHEN o.priority = 'URGENT' THEN pg_temp.rint(1, 6) ELSE pg_temp.rint(6, 72) END) AS performed_at) t
CROSS JOIN LATERAL (SELECT random() < 0.05 AS critical) c
WHERE o.order_status = 'COMPLETED';

-- ------------------------------------------------------------
-- 8. Summary (not part of the load)
-- ------------------------------------------------------------
SELECT 'persons (truth)' AS what, COUNT(*) FROM audit.synthetic_person
UNION ALL SELECT 'lis_a.patient',  COUNT(*) FROM lis_a.patient
UNION ALL SELECT 'lis_a.request',  COUNT(*) FROM lis_a.request
UNION ALL SELECT 'lis_a.result',   COUNT(*) FROM lis_a.result
UNION ALL SELECT 'lis_b.patients', COUNT(*) FROM lis_b.patients
UNION ALL SELECT 'lis_b.episodes', COUNT(*) FROM lis_b.episodes
UNION ALL SELECT 'lis_b.observations', COUNT(*) FROM lis_b.observations
UNION ALL SELECT 'ris.patient',    COUNT(*) FROM ris.patient
UNION ALL SELECT 'ris.exam_order', COUNT(*) FROM ris.exam_order
UNION ALL SELECT 'ris.report',     COUNT(*) FROM ris.report;
