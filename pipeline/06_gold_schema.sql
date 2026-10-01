-- 06_gold_schema.sql
-- gold star schema DDL (report section 3.2), Junseog, Oct 2026
--
-- 6 dimensions + 2 facts, see Figure 2 in docs/medallion_architecture.html.
-- gold is the only layer the dashboards read. no names / dob / medicare here,
-- patients are identified by the golden id from 05_resolve_identity.sql.
--
-- one change from Figure 2: fact_pathology_result PK is result_id, not
-- (request_id, loinc_code). a local test code with no LOINC mapping would give
-- a NULL loinc_code and break the composite key. result_id is always unique.
--
-- DDL only, data comes from 07_load_gold.py. drops and recreates the 8 tables.

CREATE SCHEMA IF NOT EXISTS gold;

DROP TABLE IF EXISTS gold.fact_pathology_result CASCADE;
DROP TABLE IF EXISTS gold.fact_imaging_study    CASCADE;
DROP TABLE IF EXISTS gold.dim_patient           CASCADE;
DROP TABLE IF EXISTS gold.dim_date              CASCADE;
DROP TABLE IF EXISTS gold.dim_site              CASCADE;
DROP TABLE IF EXISTS gold.dim_referrer          CASCADE;
DROP TABLE IF EXISTS gold.dim_test              CASCADE;
DROP TABLE IF EXISTS gold.dim_procedure         CASCADE;

-- dimensions. all except patient get an UNKNOWN row (key 0) so a fact with a
-- missing code still has a valid FK and shows as "unknown" instead of dropping out.

-- patient: keyed on the golden id. only sex, birth year, postcode.
CREATE TABLE gold.dim_patient (
    patient_key   SERIAL       PRIMARY KEY,
    patient_id    VARCHAR(40)  NOT NULL UNIQUE,   -- silver.patient.golden_id (uuid as text)
    sex_code      CHAR(1)      NOT NULL,          -- M / F / U
    birth_year    INTEGER,
    postcode      VARCHAR(4),
    source_system_count SMALLINT NOT NULL DEFAULT 1   -- how many source systems held this person
);
COMMENT ON TABLE gold.dim_patient IS 'one row per golden patient, no identifying attributes';

-- calendar. date_key = YYYYMMDD int so facts can be filtered without a join.
CREATE TABLE gold.dim_date (
    date_key      INTEGER      PRIMARY KEY,       -- 20260902
    full_date     DATE         NOT NULL UNIQUE,
    year_number   SMALLINT     NOT NULL,
    quarter_number SMALLINT    NOT NULL,
    month_number  SMALLINT     NOT NULL,
    month_name    VARCHAR(9)   NOT NULL,
    day_of_week   SMALLINT     NOT NULL,          -- 1 = Monday ... 7 = Sunday (ISO)
    day_name      VARCHAR(9)   NOT NULL,
    is_weekend    BOOLEAN      NOT NULL
);

CREATE TABLE gold.dim_site (
    site_key      SERIAL       PRIMARY KEY,
    site_code     VARCHAR(10)  NOT NULL UNIQUE,   -- CC012, SITE07 ...
    site_name     VARCHAR(80)  NOT NULL,
    state         VARCHAR(3)                      -- NSW, VIC ... (synthetic)
);

CREATE TABLE gold.dim_referrer (
    referrer_key    SERIAL      PRIMARY KEY,
    provider_number VARCHAR(16) NOT NULL UNIQUE,  -- referring doctor / ordering provider code
    specialty       VARCHAR(40)
);

-- pathology test, keyed on LOINC (R4 terminology harmonisation)
CREATE TABLE gold.dim_test (
    test_key      SERIAL       PRIMARY KEY,
    loinc_code    VARCHAR(10)  NOT NULL UNIQUE,   -- 718-7 ...
    test_name     VARCHAR(80)  NOT NULL,
    unit          VARCHAR(20)
);

-- imaging procedure
CREATE TABLE gold.dim_procedure (
    procedure_key  SERIAL      PRIMARY KEY,
    procedure_code VARCHAR(10) NOT NULL UNIQUE,   -- CTABDO, XRCHEST ...
    procedure_name VARCHAR(80) NOT NULL,
    modality       VARCHAR(4)                     -- CR, CT, MR, US
);

-- facts. one row per analyte result / per imaging study.
CREATE TABLE gold.fact_pathology_result (
    result_id          BIGINT       PRIMARY KEY,           -- silver.pathology_result.result_id
    request_id         VARCHAR(20)  NOT NULL,              -- degenerate dimension (req_no / accession)
    patient_key        INTEGER      NOT NULL REFERENCES gold.dim_patient(patient_key),
    date_key           INTEGER      NOT NULL REFERENCES gold.dim_date(date_key),      -- collection date
    site_key           INTEGER      NOT NULL REFERENCES gold.dim_site(site_key),
    referrer_key       INTEGER      NOT NULL REFERENCES gold.dim_referrer(referrer_key),
    test_key           INTEGER      NOT NULL REFERENCES gold.dim_test(test_key),
    source_system      VARCHAR(10)  NOT NULL,              -- lis_a / lis_b (lineage)
    priority           VARCHAR(10)  NOT NULL,              -- ROUTINE / URGENT
    result_value       NUMERIC(12,4),
    unit               VARCHAR(20),
    abnormal_flag      VARCHAR(4)   NOT NULL,              -- N / L / H
    is_abnormal        BOOLEAN      NOT NULL,
    turnaround_minutes INTEGER                             -- verified_at - collected_at
);
CREATE INDEX ix_fpr_patient ON gold.fact_pathology_result(patient_key);
CREATE INDEX ix_fpr_date    ON gold.fact_pathology_result(date_key);
CREATE INDEX ix_fpr_site    ON gold.fact_pathology_result(site_key);

CREATE TABLE gold.fact_imaging_study (
    accession_number VARCHAR(20)  PRIMARY KEY,             -- silver.imaging_report.accession_number
    patient_key      INTEGER      NOT NULL REFERENCES gold.dim_patient(patient_key),
    date_key         INTEGER      NOT NULL REFERENCES gold.dim_date(date_key),        -- order date
    site_key         INTEGER      NOT NULL REFERENCES gold.dim_site(site_key),
    referrer_key     INTEGER      NOT NULL REFERENCES gold.dim_referrer(referrer_key),
    procedure_key    INTEGER      NOT NULL REFERENCES gold.dim_procedure(procedure_key),
    source_system    VARCHAR(10)  NOT NULL,                -- ris
    priority         VARCHAR(10)  NOT NULL,
    report_status    VARCHAR(12)  NOT NULL,                -- PRELIM / FINAL
    critical_finding BOOLEAN      NOT NULL,
    turnaround_hours INTEGER                               -- verified_at - order time
);
CREATE INDEX ix_fis_patient ON gold.fact_imaging_study(patient_key);
CREATE INDEX ix_fis_date    ON gold.fact_imaging_study(date_key);
CREATE INDEX ix_fis_site    ON gold.fact_imaging_study(site_key);
