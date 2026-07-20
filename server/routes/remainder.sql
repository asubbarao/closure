-- routes/remainder.sql — residual / possible-missed-redaction APIs + panel shell.
--
-- Depends on: residual_pii_candidates, entity_groups, entity_group_members,
--             entity_address_canon (remainder_scan.sql), documents, app_templates.
-- Mutations: none here — one-tap add POSTs the existing /api/documents/:id/add route.

-- Per-document residual PII candidates (false-negative catcher queue).
CREATE OR REPLACE ROUTE api_doc_missed GET '/api/documents/:id/missed' AS
SELECT
    r.id,
    r.document_id,
    d.filename,
    d.case_id,
    r.page,
    r.x0, r.y0, r.x1, r.y1,
    r.text,
    r.kind,
    r.why,
    r.detector,
    r.score,
    r.entity_id
FROM residual_pii_candidates r
JOIN documents d ON d.id = r.document_id
WHERE r.document_id = $id::INTEGER
ORDER BY r.page, r.y0, r.x0, r.id;

-- Case-level residual PII candidates across all documents in the case.
CREATE OR REPLACE ROUTE api_case_missed GET '/api/cases/:id/missed' AS
SELECT
    r.id,
    r.document_id,
    d.filename,
    d.case_id,
    r.page,
    r.x0, r.y0, r.x1, r.y1,
    r.text,
    r.kind,
    r.why,
    r.detector,
    r.score,
    r.entity_id
FROM residual_pii_candidates r
JOIN documents d ON d.id = r.document_id
WHERE d.case_id = $id::INTEGER
ORDER BY d.filename, r.page, r.y0, r.x0, r.id;

-- Entity bulk groups (address-standardized + rapidfuzz name variants).
-- Feeds the funnel: batch-judge one group instead of N near-duplicate entities.
CREATE OR REPLACE ROUTE api_case_entity_groups GET '/api/cases/:id/entity-groups' AS
SELECT
    g.group_id,
    g.case_id,
    g.group_key,
    g.root_entity_id,
    g.canonical_label,
    g.group_kind,
    g.member_count,
    g.variant_count
FROM v_entity_groups g
WHERE g.case_id = $id::INTEGER
ORDER BY g.group_kind, g.variant_count DESC, g.canonical_label;

-- Members of one group (or all members for a case when group_id omitted via 0).
CREATE OR REPLACE ROUTE api_case_entity_group_members GET '/api/cases/:id/entity-groups/members'
  PARAM group_id INTEGER DEFAULT 0
AS
SELECT
    m.member_id,
    m.group_id,
    m.case_id,
    m.group_kind,
    m.canonical_label,
    m.entity_id,
    m.variant_text,
    m.score,
    m.method,
    m.is_full_address,
    m.is_canonical
FROM entity_group_members m
WHERE m.case_id = $id::INTEGER
  AND ($group_id::INTEGER = 0 OR m.group_id = $group_id::INTEGER)
ORDER BY m.group_id, m.is_canonical DESC, m.score DESC, m.variant_text;

-- Standardized address entities for a case (addrust components + group key).
CREATE OR REPLACE ROUTE api_case_address_canon GET '/api/cases/:id/address-canon' AS
SELECT
    c.entity_id,
    c.case_id,
    c.raw_text,
    c.kind,
    c.street_number,
    c.pre_direction,
    c.street_name,
    c.suffix,
    c.city,
    c.state,
    c.zip,
    c.po_box,
    c.is_full_address,
    c.is_street_fp_bait,
    c.group_key,
    c.standardized_text
FROM entity_address_canon c
WHERE c.case_id = $id::INTEGER
ORDER BY c.is_full_address DESC, c.group_key, c.entity_id;

-- Optional standalone panel page (self-contained; review UI also injects via remainder.js).
CREATE OR REPLACE ROUTE ui_missed_panel GET '/ui/missed'
  PARAM doc INTEGER DEFAULT 0
  PARAM case_id INTEGER DEFAULT 0
  PARAM page INTEGER DEFAULT 1
AS
SELECT tera_render(
    (SELECT content FROM app_templates WHERE name = 'remainder_panel.html'),
    {
        'doc_id': coalesce($doc::INTEGER, 0),
        'case_id': coalesce($case_id::INTEGER, 0),
        'page_no': coalesce($page::INTEGER, 1),
        'standalone': true
    }::JSON
) AS html;
