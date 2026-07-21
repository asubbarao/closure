-- routes/remainder.sql — residual PII + entity-group JSON + panel shell.
-- Hits: residual_pii_hits (remainder_scan). Groups: v_entity_groups / members / address_canon.

CREATE OR REPLACE ROUTE api_doc_missed GET '/api/documents/:id/missed' AS
SELECT
    r.id, r.document_id, d.filename, d.case_id, r.page,
    r.bbox.x0 AS x0, r.bbox.y0 AS y0, r.bbox.x1 AS x1, r.bbox.y1 AS y1,
    r.text, r.kind, r.why, r.detector, r.score, r.entity_id
FROM residual_pii_hits r
JOIN documents d ON cast(d.id AS VARCHAR) = cast(r.document_id AS VARCHAR)
WHERE cast(r.document_id AS VARCHAR) = $id
ORDER BY r.page, r.bbox.y0, r.bbox.x0, r.id;

CREATE OR REPLACE ROUTE api_case_missed GET '/api/cases/:id/missed' AS
SELECT
    r.id, r.document_id, d.filename, d.case_id, r.page,
    r.bbox.x0 AS x0, r.bbox.y0 AS y0, r.bbox.x1 AS x1, r.bbox.y1 AS y1,
    r.text, r.kind, r.why, r.detector, r.score, r.entity_id
FROM residual_pii_hits r
JOIN documents d ON cast(d.id AS VARCHAR) = cast(r.document_id AS VARCHAR)
WHERE d.case_id = $id
ORDER BY d.filename, r.page, r.bbox.y0, r.bbox.x0, r.id;

CREATE OR REPLACE ROUTE api_case_entity_groups GET '/api/cases/:id/entity-groups' AS
SELECT
    g.group_id, g.case_id, g.group_key, g.root_entity_id,
    g.canonical_label, g.group_kind, g.member_count, g.variant_count
FROM v_entity_groups g
WHERE cast(g.case_id AS VARCHAR) = $id
ORDER BY g.group_kind, g.variant_count DESC, g.canonical_label;

-- group_id=0 → all members for the case (surrogate int from remainder_scan).
CREATE OR REPLACE ROUTE api_case_entity_group_members GET '/api/cases/:id/entity-groups/members'
  PARAM group_id INTEGER DEFAULT 0
AS
SELECT
    m.member_id, m.group_id, m.case_id, m.group_kind, m.canonical_label,
    m.entity_id, m.variant_text, m.score, m.method, m.is_full_address, m.is_canonical
FROM entity_group_members m
WHERE cast(m.case_id AS VARCHAR) = $id
  AND (coalesce($group_id, 0) = 0 OR m.group_id = $group_id)
ORDER BY m.group_id, m.is_canonical DESC, m.score DESC, m.variant_text;

CREATE OR REPLACE ROUTE api_case_address_canon GET '/api/cases/:id/address-canon' AS
SELECT
    c.entity_id, c.case_id, c.raw_text, c.kind,
    c.street_number, c.pre_direction, c.street_name, c.suffix,
    c.city, c.state, c.zip, c.po_box,
    c.is_full_address, c.is_street_fp_bait, c.group_key, c.standardized_text
FROM entity_address_canon c
WHERE cast(c.case_id AS VARCHAR) = $id
ORDER BY c.is_full_address DESC, c.group_key, c.entity_id;

CREATE OR REPLACE ROUTE ui_missed_panel GET '/ui/missed'
  PARAM doc VARCHAR DEFAULT ''
  PARAM case_id VARCHAR DEFAULT ''
  PARAM page INTEGER DEFAULT 1
AS
SELECT tera_render(
    (SELECT content FROM app_templates WHERE name = 'remainder_panel.html'),
    {
        'doc_id': coalesce($doc, ''),
        'case_id': coalesce($case_id, ''),
        'page_no': coalesce($page, 1),
        'standalone': true
    }::JSON
) AS html;
