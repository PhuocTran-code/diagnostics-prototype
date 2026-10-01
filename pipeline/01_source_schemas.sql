-- Dummy source schemas for a pathology and radiology provider (synthetic data)
--   lis_a : legacy pathology LIS  (local test codes, text dates)
--   lis_b : second pathology LIS  (LOINC codes, ISO timestamps)
--   ris   : radiology information system
-- Three tables per source. The same patient appears in all three under different ids.

DROP SCHEMA IF EXISTS lis_a CASCADE;  CREATE SCHEMA lis_a;
DROP SCHEMA IF EXISTS lis_b CASCADE;  CREATE SCHEMA lis_b;
DROP SCHEMA IF EXISTS ris   CASCADE;  CREATE SCHEMA ris;

-- lis_a --------------------------------------------------------------------
CREATE TABLE lis_a.patient (
    pat_no      VARCHAR(12) PRIMARY KEY,
    medicare_no VARCHAR(11),
    surname     VARCHAR(60),
    given_names VARCHAR(80),
    dob         VARCHAR(10),        -- DD/MM/YYYY as text
    sex         CHAR(1),            -- M / F / U
    postcode    VARCHAR(4)
);

CREATE TABLE lis_a.request (
    req_no          VARCHAR(14) PRIMARY KEY,
    pat_no          VARCHAR(12) REFERENCES lis_a.patient(pat_no),
    ref_doctor_code VARCHAR(10),
    site_code       VARCHAR(8),
    coll_dt         VARCHAR(19),    -- DD/MM/YYYY HH24:MI:SS
    priority        VARCHAR(1),     -- R routine, U urgent
    status          VARCHAR(2)      -- IP in progress, FN final, CN cancelled
);

CREATE TABLE lis_a.result (
    result_id    BIGINT PRIMARY KEY,
    req_no       VARCHAR(14) REFERENCES lis_a.request(req_no),
    test_code    VARCHAR(8),        -- local mnemonic: HB, GLUC, TSH
    test_name    VARCHAR(80),
    result_value VARCHAR(40),       -- stored as text
    unit         VARCHAR(20),
    abn_flag     VARCHAR(2),        -- L, H, blank
    verified_dt  VARCHAR(19)
);

-- lis_b --------------------------------------------------------------------
CREATE TABLE lis_b.patients (
    patient_guid    UUID PRIMARY KEY,
    medicare_number VARCHAR(11),
    family_name     VARCHAR(60),
    given_name      VARCHAR(60),
    birth_date      DATE,
    administrative_sex VARCHAR(10), -- male / female / unknown
    postcode        VARCHAR(4)
);

CREATE TABLE lis_b.episodes (
    episode_id        UUID PRIMARY KEY,
    patient_guid      UUID REFERENCES lis_b.patients(patient_guid),
    accession_number  VARCHAR(20) UNIQUE,
    ordering_provider VARCHAR(16),
    site_code         VARCHAR(10),
    collected_utc     TIMESTAMPTZ,
    urgency           VARCHAR(10), -- routine / urgent
    episode_status    VARCHAR(12)  -- in_progress / final / cancelled
);

CREATE TABLE lis_b.observations (
    observation_id BIGINT PRIMARY KEY,
    episode_id     UUID REFERENCES lis_b.episodes(episode_id),
    loinc_code     VARCHAR(10),
    analyte_name   VARCHAR(80),
    value_numeric  NUMERIC(12,4),
    ucum_unit      VARCHAR(20),
    interpretation VARCHAR(4),      -- N, L, H
    reported_utc   TIMESTAMPTZ
);

-- ris ----------------------------------------------------------------------
CREATE TABLE ris.patient (
    ris_patient_id INTEGER PRIMARY KEY,
    medicare_no    VARCHAR(11),
    last_name      VARCHAR(60),
    first_name     VARCHAR(60),
    date_of_birth  DATE,
    gender         VARCHAR(1),      -- M / F / U
    postcode       VARCHAR(4)
);

CREATE TABLE ris.exam_order (
    accession_number VARCHAR(16) PRIMARY KEY,
    ris_patient_id   INTEGER REFERENCES ris.patient(ris_patient_id),
    referrer_code    VARCHAR(10),
    site_code        VARCHAR(8),
    procedure_code   VARCHAR(10),   -- XRCHEST, CTABDO
    modality         VARCHAR(4),    -- CR, CT, MR, US
    order_datetime   TIMESTAMP,
    priority         VARCHAR(8),    -- ROUTINE / URGENT
    order_status     VARCHAR(12)    -- SCHEDULED / COMPLETED / CANCELLED
);

CREATE TABLE ris.report (
    report_id        INTEGER PRIMARY KEY,
    accession_number VARCHAR(16) REFERENCES ris.exam_order(accession_number),
    radiologist_code VARCHAR(16),
    performed_at     TIMESTAMP,
    verified_at      TIMESTAMP,
    report_status    VARCHAR(12),   -- PRELIM / FINAL
    critical_finding BOOLEAN,
    report_text      TEXT
);

-- Sample rows: one patient in all three systems ------------------------------
INSERT INTO lis_a.patient VALUES ('P0001234','2123456781','NGUYEN','MINH THI','14/03/1968','F','2000');
INSERT INTO lis_a.request VALUES ('26R0000001','P0001234','2451371X','CC012','02/09/2026 08:30:00','R','FN');
INSERT INTO lis_a.result  VALUES
 (1001,'26R0000001','HB','Haemoglobin','118','g/L','L','02/09/2026 11:45:00'),
 (1002,'26R0000001','GLUC','Glucose fasting','6.4','mmol/L','H','02/09/2026 12:20:00');

INSERT INTO lis_b.patients VALUES ('7c9e6679-7425-40de-944b-e07fc1f90ae7','2123456781','Nguyen','Minh','1968-03-14','female','2000');
INSERT INTO lis_b.episodes VALUES ('0f8fad5b-d9cb-469f-a165-70867728950e','7c9e6679-7425-40de-944b-e07fc1f90ae7','LB26-000771','2451371X','SITE07','2026-08-20T00:40:00Z','routine','final');
INSERT INTO lis_b.observations VALUES
 (5001,'0f8fad5b-d9cb-469f-a165-70867728950e','718-7','Haemoglobin',121.0,'g/L','N','2026-08-20T03:20:00Z'),
 (5002,'0f8fad5b-d9cb-469f-a165-70867728950e','1742-6','ALT',58.0,'U/L','H','2026-08-20T03:20:00Z');

INSERT INTO ris.patient    VALUES (90001,'2123456781','NGUYEN','MINH','1968-03-14','F','2000');
INSERT INTO ris.exam_order VALUES ('RIS26-004411',90001,'2451371X','SITE07','CTABDO','CT','2026-09-03 09:05:00','ROUTINE','COMPLETED');
INSERT INTO ris.report     VALUES (80001,'RIS26-004411','RAD05','2026-09-04 14:12:00','2026-09-04 17:02:00','FINAL',FALSE,'CT abdomen: no focal lesion.');

-- A second patient, present in lis_a only. No match should be found for
-- this one in the graph MPI step -- it is what makes the raw-vs-golden
-- identifier count (see V4 below) a meaningful test rather than a
-- trivial 3-to-1 case.
INSERT INTO lis_a.patient VALUES ('P0001235','2987654321','TRAN','VAN DUC','22/11/1975','M','2010');
INSERT INTO lis_a.request VALUES ('26R0000002','P0001235','2451371X','CC012','05/09/2026 09:15:00','R','FN');
INSERT INTO lis_a.result  VALUES
 (1003,'26R0000002','HB','Haemoglobin','142','g/L',' ','05/09/2026 12:05:00');


-- ============================================================
-- SILVER LAYER: cleaned, conformed, one row per source-system
-- patient/request/result. Identity is NOT resolved here -- that is
-- the job of the graph MPI step (diagnostics_graph_mpi.cypher).
-- Silver is historised on the golden patient only, so a change in
-- a person's recorded details doesn't overwrite what dashboards
-- have already reported against.
-- ============================================================
DROP SCHEMA IF EXISTS silver CASCADE; CREATE SCHEMA silver;

-- One conformed row per source-system patient record. This is what
-- is the input to identity resolution (05_resolve_identity.sql).
CREATE TABLE silver.patient_source (
    patient_source_key  BIGSERIAL PRIMARY KEY,
    source_system       VARCHAR(10) NOT NULL,   -- lis_a / lis_b / ris
    source_patient_id   VARCHAR(40) NOT NULL,   -- pat_no / patient_guid / ris_patient_id
    medicare_no         VARCHAR(11),
    family_name         VARCHAR(60),
    given_name          VARCHAR(80),
    dob                 DATE,
    sex_code            CHAR(1),                -- conformed to M / F / U
    postcode            VARCHAR(4),
    loaded_at           TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    UNIQUE (source_system, source_patient_id)
);

-- Golden (resolved) patient. golden_id stays stable across history rows;
-- patient_key is the surrogate that gold.dim_patient keys off.
CREATE TABLE silver.patient (
    patient_key  BIGSERIAL PRIMARY KEY,
    golden_id    UUID NOT NULL,
    family_name  VARCHAR(60),
    given_name   VARCHAR(80),
    dob          DATE,
    sex_code     CHAR(1),
    postcode     VARCHAR(4),
    valid_from   TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    valid_to     TIMESTAMP,
    is_current   BOOLEAN NOT NULL DEFAULT TRUE
);

-- Crosswalk written back from the graph MPI resolution: which source
-- record resolved to which golden patient, and on what basis.
CREATE TABLE silver.patient_xref (
    patient_source_key BIGINT PRIMARY KEY REFERENCES silver.patient_source(patient_source_key),
    patient_key         BIGINT REFERENCES silver.patient(patient_key),
    match_basis         VARCHAR(30),   -- 'medicare+dob' / 'unmatched (single source)'
    resolved_at         TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- Local/LOINC/procedure code crosswalk -- supports R4 (terminology
-- harmonisation) and is what silver ETL joins against instead of
-- hard-coding the mapping in Python.
CREATE TABLE silver.test_code_map (
    source_system  VARCHAR(10) NOT NULL,
    source_code    VARCHAR(20) NOT NULL,
    loinc_code     VARCHAR(10),          -- NULL for imaging procedures
    test_name      VARCHAR(80),
    modality       VARCHAR(10),          -- imaging only
    PRIMARY KEY (source_system, source_code)
);

INSERT INTO silver.test_code_map (source_system, source_code, loinc_code, test_name, modality) VALUES
 ('lis_a','HB','718-7','Haemoglobin',NULL),
 ('lis_a','GLUC','15074-8','Glucose (fasting)',NULL),
 ('lis_b','718-7','718-7','Haemoglobin',NULL),
 ('lis_b','1742-6','1742-6','ALT',NULL),
 ('ris','CTABDO',NULL,'CT abdomen','CT'),
 ('ris','XRCHEST',NULL,'Chest X-ray','CR');

-- Conformed request/result tables. request_type distinguishes the two
-- fact tables that both come off the one diagnostic_request.
CREATE TABLE silver.diagnostic_request (
    request_id          VARCHAR(20) PRIMARY KEY,  -- req_no / accession_number
    patient_source_key  BIGINT REFERENCES silver.patient_source(patient_source_key),
    referrer_code       VARCHAR(16),
    site_code           VARCHAR(10),
    request_type        VARCHAR(10),   -- PATHOLOGY / IMAGING
    collected_at        TIMESTAMP,
    priority            VARCHAR(10),   -- ROUTINE / URGENT, conformed
    status              VARCHAR(12),   -- IN_PROGRESS / FINAL / CANCELLED, conformed
    source_system       VARCHAR(10)
);

CREATE TABLE silver.pathology_result (
    result_id       BIGINT PRIMARY KEY,
    request_id      VARCHAR(20) REFERENCES silver.diagnostic_request(request_id),
    loinc_code      VARCHAR(10),
    test_name       VARCHAR(80),
    result_value    NUMERIC(12,4),
    unit            VARCHAR(20),
    abnormal_flag   VARCHAR(4),    -- N / L / H, conformed
    verified_at     TIMESTAMP
);

CREATE TABLE silver.imaging_report (
    accession_number  VARCHAR(20) PRIMARY KEY REFERENCES silver.diagnostic_request(request_id),
    procedure_code    VARCHAR(10),
    modality          VARCHAR(4),
    performed_at      TIMESTAMP,
    verified_at       TIMESTAMP,
    report_status     VARCHAR(12),  -- PRELIM / FINAL
    critical_finding  BOOLEAN
);


-- ============================================================
-- AUDIT LAYER: one run record per load, per the Workshop 6 pattern.
-- ============================================================
DROP SCHEMA IF EXISTS audit CASCADE; CREATE SCHEMA audit;

CREATE TABLE audit.pipeline_run (
    run_id         BIGSERIAL PRIMARY KEY,
    layer          VARCHAR(10),   -- bronze / silver / graph / gold
    source_name    VARCHAR(20),
    target_table   VARCHAR(60),
    rows_read      INT,
    rows_loaded    INT,
    run_status     VARCHAR(10),   -- SUCCESS / FAILED
    started_at     TIMESTAMP,
    completed_at   TIMESTAMP
);


-- ============================================================
-- END-TO-END VALIDATION QUERIES (evidence for section 3.5)
-- Run each after the relevant layer has loaded. Expected result is
-- noted in the comment; a non-zero/unexpected result is what the
-- demo video should show being caught, not just the happy path.
-- ============================================================

-- V1: every silver request resolves to a known patient source record
-- Expect: 0
SELECT COUNT(*) AS orphan_requests
FROM silver.diagnostic_request r
LEFT JOIN silver.patient_source p ON r.patient_source_key = p.patient_source_key
WHERE p.patient_source_key IS NULL;

-- V2: every patient_source row has been resolved by the graph MPI step
-- Expect: 0, once 05_resolve_identity has run
SELECT COUNT(*) AS unresolved_patient_records
FROM silver.patient_source ps
LEFT JOIN silver.patient_xref x ON ps.patient_source_key = x.patient_source_key
WHERE x.patient_source_key IS NULL;

-- V3: row-count reconciliation, bronze -> silver, per source
-- Expect: silver_rows <= bronze_rows, with the difference explainable
-- (duplicates dropped, malformed rows rejected) not silent data loss
-- Example for lis_a (repeat per source):
-- SELECT
--   (SELECT COUNT(*) FROM bronze.lis_a_patient) AS bronze_rows,
--   (SELECT COUNT(*) FROM silver.patient_source WHERE source_system='lis_a') AS silver_rows;

-- V4: identity resolution impact -- the headline MPI metric, and the
-- dashboard use case that most directly demonstrates R1 from A1
SELECT
    (SELECT COUNT(*) FROM silver.patient_source)                    AS raw_identifiers,
    (SELECT COUNT(DISTINCT patient_key) FROM silver.patient_xref)   AS golden_patients,
    (SELECT COUNT(*) FROM silver.patient_source)
      - (SELECT COUNT(DISTINCT patient_key) FROM silver.patient_xref) AS duplicates_resolved;
