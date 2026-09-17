// ============================================================
// Graph MPI (master patient index) step
// ------------------------------------------------------------
// Sits between silver (per-source, conformed) and gold (star
// schema) in diagnostics_medallion_architecture.html. Implements
// A1's Recommendation R1 -- "graph-based identity model" -- as a
// deterministic version: patients are the same person if their
// Medicare number and date of birth agree, wherever they came from.
//
// Input:  silver.patient_source (Postgres) -- exported by the
//         Python ETL step, one row per source-system patient record.
// Output: silver.patient + silver.patient_xref (Postgres) -- written
//         back after resolution below.
//
// Run order: 1) constraints, 2) load nodes, 3) create SAME_AS edges,
// 4) resolve to golden ids, 5) export crosswalk.
// ============================================================


// ---- 1. Constraints --------------------------------------------------
// One node per (source_system, source_patient_id), matching the
// UNIQUE constraint on silver.patient_source.
CREATE CONSTRAINT patient_record_id IF NOT EXISTS
FOR (p:PatientRecord) REQUIRE (p.source_system, p.source_patient_id) IS UNIQUE;


// ---- 2. Load nodes -----------------------------------------------------
// The Python export step (04_export_to_neo4j.py) runs this once per
// row read from silver.patient_source, passing $records as a list of
// maps. Shown here with UNWIND so the whole batch loads in one query.
UNWIND $records AS record
MERGE (p:PatientRecord {
  source_system:     record.source_system,
  source_patient_id: record.source_patient_id
})
SET p.medicare_no  = record.medicare_no,
    p.family_name  = record.family_name,
    p.given_name   = record.given_name,
    p.dob          = date(record.dob),
    p.postcode     = record.postcode;


// ---- 3. Create SAME_AS edges -------------------------------------------
// Deterministic match: same Medicare number AND same date of birth,
// across two DIFFERENT source systems. (Matching a record to itself,
// or to another record from its own source, is not identity resolution.)
MATCH (a:PatientRecord), (b:PatientRecord)
WHERE a.source_system < b.source_system          // avoid duplicate pairs and self-pairs
  AND a.medicare_no = b.medicare_no
  AND a.dob = b.dob
  AND a.medicare_no IS NOT NULL
MERGE (a)-[:SAME_AS {basis: 'medicare+dob'}]-(b);


// ---- 4. Resolve to golden ids -------------------------------------------
// Every connected component of SAME_AS edges is one person. Records
// with no SAME_AS edge at all are their own component (see the
// lis_a-only patient in the sample data -- expected to stay unmatched).
// gds.wcc requires the Graph Data Science library; the CALL block
// below is the intended production path. A driver-side fallback
// (plain Cypher, no GDS) follows for lab environments without it.

// -- Preferred: Graph Data Science weakly-connected-components --
// CALL gds.graph.project('patientMatch', 'PatientRecord', 'SAME_AS')
// YIELD graphName;
// CALL gds.wcc.write('patientMatch', { writeProperty: 'golden_component' })
// YIELD componentCount, nodePropertiesWritten;
// CALL gds.graph.drop('patientMatch');

// -- Fallback without GDS: assign golden_id per component using
// apoc.path.subgraphNodes to walk each SAME_AS component and stamp
// every member with one generated id.
MATCH (p:PatientRecord)
WHERE NOT EXISTS(p.golden_id)
CALL {
  WITH p
  MATCH path = (p)-[:SAME_AS*0..]-(linked:PatientRecord)
  WITH collect(DISTINCT linked) AS component
  WITH component, apoc.create.uuid() AS golden_id
  UNWIND component AS member
  SET member.golden_id = golden_id
}
RETURN count(*) AS patients_resolved;


// ---- 5. Export the crosswalk --------------------------------------------
// The Python step reads this result set and writes it into
// silver.patient_xref (one row per patient_source_key) plus one row
// per distinct golden_id into silver.patient.
MATCH (p:PatientRecord)
RETURN
  p.source_system      AS source_system,
  p.source_patient_id  AS source_patient_id,
  p.golden_id           AS golden_id,
  p.family_name         AS family_name,
  p.given_name           AS given_name,
  p.dob                     AS dob,
  p.postcode               AS postcode,
  CASE WHEN size((p)-[:SAME_AS]-()) = 0
       THEN 'unmatched (single source)'
       ELSE 'medicare+dob'
  END AS match_basis
ORDER BY golden_id, source_system;


// ---- Verification queries (useful for the 3.5 demo video) --------------

// How many source records collapsed into how many golden patients --
// this is the same headline number as V4 in diagnostics_source_schemas.sql,
// computed here directly on the graph as a cross-check.
// MATCH (p:PatientRecord)
// RETURN count(p) AS raw_identifiers, count(DISTINCT p.golden_id) AS golden_patients;

// Visualise one resolved identity cluster in Neo4j Browser:
// MATCH path = (p:PatientRecord {golden_id: $golden_id})-[:SAME_AS*0..]-(linked)
// RETURN path;
