-- pdf_io.sql — sole PDF I/O service surface for HTTP / export / scanned-page OCR.
--
-- Purpose:
--   1. Geometry + pdf_redact SQL builders (export / working copies).
--   2. Scanned-document path: detect image-only pages, OCR when available,
--      land words with source='ocr' into the same words table, and surface a
--      per-document library badge when a scan has no usable text layer.
--
-- Load order (app.sql): AFTER ingest (documents/pages exist), BEFORE seed
-- (suggestions must see OCR words). Export macros only evaluate at call time
-- so they may be defined before v_suggestions exists.
--
-- OCR availability:
--   Community `pdf` (INSTALL pdf FROM community) already ships auto_ocr /
--   source / confidence. Local unsigned build at
--   ~/duckdb-read_pdf/build/release/extension/pdf/pdf.duckdb_extension adds
--   has_text_layer / used_ocr. Both need a Tesseract eng model (Homebrew
--   tessdata is auto-detected). See docs/scanned-docs.md.
--
-- Must NOT be called from templates or static JS (routes + CTAS only).

-- ═══════════════════════════════════════════════════════════════════════════
-- Config + capability
-- ═══════════════════════════════════════════════════════════════════════════

-- Optional explicit tessdata override (empty → extension auto-detect).
CREATE OR REPLACE MACRO cfg_tessdata_dir() AS '';

-- Literal glob for extra image-only / scan fixtures (not in samples/manifest).
CREATE OR REPLACE MACRO cfg_scan_fixture_glob() AS 'spikes/scans/fixtures/*.pdf';

-- Probe: community/local pdf extension exposes OCR named params.
CREATE OR REPLACE TABLE pdf_ocr_capability AS
WITH
fn AS (
    SELECT
        function_name,
        parameters,
        list_contains(parameters, 'auto_ocr') AS has_auto_ocr,
        list_contains(parameters, 'ocr') AS has_ocr_flag,
        list_contains(parameters, 'tessdata_dir') AS has_tessdata_dir
    FROM duckdb_functions()
    WHERE function_name = 'read_pdf_words'
    LIMIT 1
),
-- Best-effort live probe on the committed image-only fixture (source='ocr').
probe AS (
    SELECT
        count(*)::BIGINT AS probe_word_count,
        count(*) FILTER (
            WHERE coalesce(source, 'text') = 'ocr'
        )::BIGINT AS probe_ocr_word_count
    FROM read_pdf_words(
        'spikes/scans/fixtures/image_only_scanned.pdf',
        auto_ocr := true
    )
)
SELECT
    coalesce((SELECT has_auto_ocr FROM fn), false) AS has_auto_ocr_param,
    coalesce((SELECT has_ocr_flag FROM fn), false) AS has_ocr_param,
    coalesce((SELECT has_tessdata_dir FROM fn), false) AS has_tessdata_dir_param,
    coalesce((SELECT probe_word_count FROM probe), 0) AS probe_word_count,
    coalesce((SELECT probe_ocr_word_count FROM probe), 0) AS probe_ocr_word_count,
    (
        coalesce((SELECT has_auto_ocr FROM fn), false)
        AND coalesce((SELECT probe_ocr_word_count FROM probe), 0) > 0
    ) AS ocr_available,
    CASE
        WHEN NOT coalesce((SELECT has_auto_ocr FROM fn), false)
        THEN 'pdf extension lacks auto_ocr — load local unsigned pdf build'
        WHEN coalesce((SELECT probe_ocr_word_count FROM probe), 0) = 0
        THEN 'auto_ocr returned 0 OCR words — install tesseract eng model (brew install tesseract)'
        ELSE 'ocr ready'
    END AS ocr_status_note,
    now() AS probed_at;

CREATE OR REPLACE MACRO pdf_ocr_available() AS (
    SELECT coalesce(
        (SELECT ocr_available FROM pdf_ocr_capability LIMIT 1),
        false
    )
);

-- ═══════════════════════════════════════════════════════════════════════════
-- Attach scan fixtures as first-class documents (case 1 demo corpus)
-- ═══════════════════════════════════════════════════════════════════════════

-- Image-only fixtures live under spikes/scans/fixtures/ (not samples/ — contract
-- forbids mutating samples/). Attach them to case 1 so the library can show
-- OCR suggestions or the scanned badge.
CREATE OR REPLACE TABLE documents AS
WITH
base AS (
    SELECT * FROM documents
),
max_id AS (
    SELECT coalesce(max(id), 0)::INTEGER AS n FROM base
),
scan_pdf AS (
    SELECT
        file AS full_path,
        regexp_replace(regexp_replace(file, '.*/', ''), '\.pdf$', '') AS stem,
        page_count::INTEGER AS page_count,
        width::DOUBLE AS width_pt,
        height::DOUBLE AS height_pt,
        file_size::BIGINT AS file_size
    FROM pdf_info(cfg_scan_fixture_glob())
),
case1 AS (
    SELECT id AS case_id FROM cases ORDER BY id LIMIT 1
),
scan_docs AS (
    SELECT
        ((SELECT n FROM max_id) + row_number() OVER (ORDER BY s.stem))::INTEGER AS id,
        (SELECT case_id FROM case1) AS case_id,
        s.stem AS filename,
        s.full_path AS source_path,
        s.page_count,
        s.width_pt,
        s.height_pt,
        s.file_size
    FROM scan_pdf s
    WHERE NOT EXISTS (
        SELECT 1 FROM base b WHERE b.filename = s.stem OR b.source_path = s.full_path
    )
)
SELECT * FROM base
UNION ALL BY NAME
SELECT * FROM scan_docs
ORDER BY id;

-- Pages: keep sample pages; append pages for scan fixtures (glob — no lateral path).
CREATE OR REPLACE TABLE pages AS
WITH
existing AS (
    SELECT * FROM pages
),
from_fixture_glob AS (
    SELECT
        d.id AS document_id,
        p.page::INTEGER AS page_no,
        coalesce(p.width, d.width_pt)::DOUBLE AS width_pt,
        coalesce(p.height, d.height_pt)::DOUBLE AS height_pt
    FROM documents d
    JOIN read_pdf(cfg_scan_fixture_glob()) p
      ON regexp_replace(regexp_replace(p.filename, '.*/', ''), '\.pdf$', '') = d.filename
    WHERE NOT EXISTS (
        SELECT 1 FROM existing e WHERE e.document_id = d.id
    )
),
series_fallback AS (
    SELECT
        d.id AS document_id,
        gs.page_no::INTEGER AS page_no,
        d.width_pt,
        d.height_pt
    FROM documents d
    CROSS JOIN LATERAL (
        SELECT unnest(generate_series(1, greatest(d.page_count, 1))) AS page_no
    ) gs
    WHERE NOT EXISTS (
        SELECT 1 FROM existing e WHERE e.document_id = d.id
    )
    AND NOT EXISTS (
        SELECT 1 FROM from_fixture_glob f WHERE f.document_id = d.id
    )
)
SELECT * FROM existing
UNION ALL BY NAME
SELECT * FROM from_fixture_glob
UNION ALL BY NAME
SELECT * FROM series_fallback
ORDER BY document_id, page_no;

-- ═══════════════════════════════════════════════════════════════════════════
-- Words: native text layer + OCR for image-only pages (same table)
-- ═══════════════════════════════════════════════════════════════════════════

-- Native-only pass (auto_ocr off) — establishes text-layer coverage per page.
CREATE OR REPLACE TABLE _words_native AS
SELECT
    d.id AS document_id,
    w.page::INTEGER AS page_no,
    cast(w.word AS VARCHAR) AS word,
    w.x0::DOUBLE AS x0,
    w.y0::DOUBLE AS y0,
    w.x1::DOUBLE AS x1,
    w.y1::DOUBLE AS y1,
    w.font_size::DOUBLE AS font_size,
    cast(coalesce(w.source, 'text') AS VARCHAR) AS source,
    w.confidence::DOUBLE AS ocr_confidence
FROM read_pdf_words('samples/*.pdf', auto_ocr := false) w
JOIN documents d
  ON d.filename = regexp_replace(regexp_replace(w.filename, '.*/', ''), '\.pdf$', '')
UNION ALL BY NAME
SELECT
    d.id AS document_id,
    w.page::INTEGER AS page_no,
    cast(w.word AS VARCHAR) AS word,
    w.x0::DOUBLE AS x0,
    w.y0::DOUBLE AS y0,
    w.x1::DOUBLE AS x1,
    w.y1::DOUBLE AS y1,
    w.font_size::DOUBLE AS font_size,
    cast(coalesce(w.source, 'text') AS VARCHAR) AS source,
    w.confidence::DOUBLE AS ocr_confidence
FROM read_pdf_words(cfg_scan_fixture_glob(), auto_ocr := false) w
JOIN documents d
  ON d.filename = regexp_replace(regexp_replace(w.filename, '.*/', ''), '\.pdf$', '');

-- Pages with zero native words (candidates for OCR / scanned badge).
CREATE OR REPLACE TABLE _pages_need_ocr AS
SELECT
    p.document_id,
    p.page_no,
    d.source_path,
    d.filename
FROM pages p
JOIN documents d ON d.id = p.document_id
WHERE NOT EXISTS (
    SELECT 1
    FROM _words_native n
    WHERE n.document_id = p.document_id AND n.page_no = p.page_no
);

-- Embedded-image presence (strong signal for "scanned / image-only").
-- pdf_images rejects lateral column paths — globs only.
CREATE OR REPLACE TABLE _page_images AS
SELECT
    d.id AS document_id,
    i.page::INTEGER AS page_no,
    count(*)::BIGINT AS image_count,
    coalesce(sum(octet_length(i.data)), 0)::BIGINT AS image_bytes
FROM pdf_images('samples/*.pdf') i
JOIN documents d
  ON d.filename = regexp_replace(regexp_replace(i.file, '.*/', ''), '\.pdf$', '')
GROUP BY d.id, i.page
UNION ALL BY NAME
SELECT
    d.id AS document_id,
    i.page::INTEGER AS page_no,
    count(*)::BIGINT AS image_count,
    coalesce(sum(octet_length(i.data)), 0)::BIGINT AS image_bytes
FROM pdf_images(cfg_scan_fixture_glob()) i
JOIN documents d
  ON d.filename = regexp_replace(regexp_replace(i.file, '.*/', ''), '\.pdf$', '')
GROUP BY d.id, i.page;

-- OCR pass: only when capability probe succeeded.
-- IMPORTANT: do NOT auto_ocr the full samples/*.pdf glob — consolidated is
-- 100+ pages and Tesseract would re-open every page. OCR only paths that have
-- zero native words (today: spikes/scans/fixtures). samples stay native-only.
CREATE OR REPLACE TABLE _words_ocr AS
SELECT
    d.id AS document_id,
    w.page::INTEGER AS page_no,
    cast(w.word AS VARCHAR) AS word,
    w.x0::DOUBLE AS x0,
    w.y0::DOUBLE AS y0,
    w.x1::DOUBLE AS x1,
    w.y1::DOUBLE AS y1,
    w.font_size::DOUBLE AS font_size,
    'ocr'::VARCHAR AS source,
    -- Slightly damp base geometry confidence for downstream band consumers.
    CASE
        WHEN w.confidence IS NULL THEN NULL
        ELSE least(w.confidence, 100.0) * 0.92
    END AS ocr_confidence
FROM read_pdf_words(cfg_scan_fixture_glob(), auto_ocr := true) w
JOIN documents d
  ON d.filename = regexp_replace(regexp_replace(w.filename, '.*/', ''), '\.pdf$', '')
WHERE pdf_ocr_available()
  AND coalesce(w.source, 'text') = 'ocr'
  AND EXISTS (
      SELECT 1 FROM _pages_need_ocr n
      WHERE n.document_id = d.id AND n.page_no = w.page
  );

-- Final words table (replaces ingest native-only CTAS).
CREATE OR REPLACE TABLE words AS
WITH merged AS (
    SELECT
        document_id, page_no, word, x0, y0, x1, y1, font_size, source, ocr_confidence
    FROM _words_native
    WHERE coalesce(source, 'text') <> 'ocr'
    UNION ALL BY NAME
    SELECT
        document_id, page_no, word, x0, y0, x1, y1, font_size, source, ocr_confidence
    FROM _words_ocr
)
SELECT
    document_id,
    page_no,
    row_number() OVER (
        PARTITION BY document_id, page_no
        ORDER BY round(y0, 1), x0, word
    )::INTEGER AS seq,
    word,
    x0, y0, x1, y1,
    font_size,
    source,
    ocr_confidence
FROM merged
ORDER BY document_id, page_no, seq;

-- Drop scratch (keep capability + scan status durable for routes).
DROP TABLE IF EXISTS _words_native;
DROP TABLE IF EXISTS _words_ocr;

-- ═══════════════════════════════════════════════════════════════════════════
-- Per-page + per-document scan status (library / store badge)
-- ═══════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE TABLE page_scan_status AS
SELECT
    p.document_id,
    p.page_no,
    coalesce(wc.native_words, 0)::BIGINT AS native_word_count,
    coalesce(wc.ocr_words, 0)::BIGINT AS ocr_word_count,
    coalesce(wc.total_words, 0)::BIGINT AS total_word_count,
    coalesce(im.image_count, 0)::BIGINT AS image_count,
    coalesce(im.image_bytes, 0)::BIGINT AS image_bytes,
    (coalesce(wc.native_words, 0) = 0) AS no_text_layer,
    (
        coalesce(wc.native_words, 0) = 0
        AND (
            coalesce(im.image_count, 0) > 0
            OR coalesce(wc.ocr_words, 0) > 0
            OR coalesce(wc.total_words, 0) = 0
        )
    ) AS is_image_only_candidate,
    CASE
        WHEN coalesce(wc.native_words, 0) > 0 THEN 'text_layer'
        WHEN coalesce(wc.ocr_words, 0) > 0 THEN 'ocr'
        WHEN coalesce(im.image_count, 0) > 0 THEN 'scanned_no_text'
        WHEN coalesce(wc.total_words, 0) = 0 THEN 'empty_or_scanned'
        ELSE 'unknown'
    END AS page_kind
FROM pages p
LEFT JOIN (
    SELECT
        document_id,
        page_no,
        count(*) FILTER (WHERE coalesce(source, 'text') = 'text')::BIGINT AS native_words,
        count(*) FILTER (WHERE source = 'ocr')::BIGINT AS ocr_words,
        count(*)::BIGINT AS total_words
    FROM words
    GROUP BY document_id, page_no
) wc ON wc.document_id = p.document_id AND wc.page_no = p.page_no
LEFT JOIN _page_images im
  ON im.document_id = p.document_id AND im.page_no = p.page_no;

CREATE OR REPLACE TABLE document_scan_status AS
WITH
agg AS (
    SELECT
        d.id AS document_id,
        d.case_id,
        d.filename,
        d.source_path,
        d.page_count,
        count(*) FILTER (WHERE ps.page_kind = 'text_layer')::BIGINT AS text_layer_pages,
        count(*) FILTER (WHERE ps.page_kind = 'ocr')::BIGINT AS ocr_pages,
        count(*) FILTER (
            WHERE ps.page_kind IN ('scanned_no_text', 'empty_or_scanned')
        )::BIGINT AS scanned_gap_pages,
        coalesce(sum(ps.native_word_count), 0)::BIGINT AS native_word_count,
        coalesce(sum(ps.ocr_word_count), 0)::BIGINT AS ocr_word_count,
        coalesce(sum(ps.total_word_count), 0)::BIGINT AS total_word_count,
        coalesce(sum(ps.image_count), 0)::BIGINT AS image_count
    FROM documents d
    LEFT JOIN page_scan_status ps ON ps.document_id = d.id
    GROUP BY d.id, d.case_id, d.filename, d.source_path, d.page_count
),
cap AS (
    SELECT ocr_available, ocr_status_note FROM pdf_ocr_capability LIMIT 1
)
SELECT
    a.document_id,
    a.case_id,
    a.filename,
    a.source_path,
    a.page_count,
    a.text_layer_pages,
    a.ocr_pages,
    a.scanned_gap_pages,
    a.native_word_count,
    a.ocr_word_count,
    a.total_word_count,
    a.image_count,
    (SELECT ocr_available FROM cap) AS ocr_available,
    (SELECT ocr_status_note FROM cap) AS ocr_status_note,
    -- Document is "scanned" when it has no native text layer on at least one page
    -- and is not a pure multi-page text doc. Primary signal: zero native words.
    (a.native_word_count = 0 AND a.page_count > 0) AS is_scanned,
    (a.native_word_count = 0 AND a.ocr_word_count > 0) AS ocr_ingested,
    (a.native_word_count = 0 AND a.ocr_word_count = 0 AND a.page_count > 0) AS scan_gap,
    CASE
        WHEN a.native_word_count > 0 AND a.ocr_word_count = 0 THEN NULL
        WHEN a.native_word_count = 0 AND a.ocr_word_count > 0 THEN 'scanned · OCR'
        WHEN a.native_word_count = 0 AND a.ocr_word_count = 0 THEN 'scanned — no text layer'
        WHEN a.ocr_word_count > 0 THEN 'mixed · OCR'
        ELSE NULL
    END AS scan_badge,
    CASE
        WHEN a.native_word_count = 0 AND a.ocr_word_count > 0 THEN 'b-blue'
        WHEN a.native_word_count = 0 AND a.ocr_word_count = 0 THEN 'b-rej'
        WHEN a.ocr_word_count > 0 THEN 'b-pend'
        ELSE 'b-gray'
    END AS scan_badge_class,
    CASE
        WHEN a.native_word_count = 0 AND a.ocr_word_count > 0
        THEN 'Image-only pages OCR''d into words (source=ocr). Review boxes before export.'
        WHEN a.native_word_count = 0 AND a.ocr_word_count = 0 AND NOT (SELECT ocr_available FROM cap)
        THEN 'Scanned / image-only PDF and OCR is not available on this host. '
             || (SELECT ocr_status_note FROM cap)
             || '. No suggestions can be generated from a missing text layer.'
        WHEN a.native_word_count = 0 AND a.ocr_word_count = 0
        THEN 'No text layer and OCR returned no words (blank or unreadable raster). '
             || 'Do not treat zero suggestions as a clean document.'
        ELSE NULL
    END AS scan_detail
FROM agg a
ORDER BY a.document_id;

CREATE OR REPLACE VIEW v_document_scan_status AS
SELECT * FROM document_scan_status;

DROP TABLE IF EXISTS _pages_need_ocr;
DROP TABLE IF EXISTS _page_images;

-- JSON route for library / store badge consumers.
CREATE OR REPLACE ROUTE api_doc_scan GET '/api/documents/:id/scan' AS
SELECT
    document_id,
    case_id,
    filename,
    source_path,
    page_count,
    text_layer_pages,
    ocr_pages,
    scanned_gap_pages,
    native_word_count,
    ocr_word_count,
    total_word_count,
    image_count,
    ocr_available,
    ocr_status_note,
    is_scanned,
    ocr_ingested,
    scan_gap,
    scan_badge,
    scan_badge_class,
    scan_detail
FROM document_scan_status
WHERE document_id = $id::INTEGER;

CREATE OR REPLACE ROUTE api_case_scan GET '/api/cases/:id/scan' AS
SELECT
    document_id,
    case_id,
    filename,
    page_count,
    native_word_count,
    ocr_word_count,
    total_word_count,
    is_scanned,
    ocr_ingested,
    scan_gap,
    scan_badge,
    scan_badge_class,
    scan_detail,
    ocr_available
FROM document_scan_status
WHERE case_id = $id::INTEGER
ORDER BY filename;

SELECT 'pdf_io OCR enrich' AS phase,
       (SELECT ocr_available FROM pdf_ocr_capability) AS ocr_available,
       (SELECT ocr_status_note FROM pdf_ocr_capability) AS ocr_status_note,
       (SELECT count(*) FROM documents) AS documents,
       (SELECT count(*) FROM words) AS words,
       (SELECT count(*) FROM words WHERE source = 'ocr') AS ocr_words,
       (SELECT count(*) FROM document_scan_status WHERE is_scanned) AS scanned_docs,
       (SELECT count(*) FROM document_scan_status WHERE ocr_ingested) AS ocr_ingested_docs,
       (SELECT count(*) FROM document_scan_status WHERE scan_gap) AS scan_gap_docs;

-- ═══════════════════════════════════════════════════════════════════════════
-- Geometry + literal box builders (pdf_redact coordinate space)
-- ═══════════════════════════════════════════════════════════════════════════

-- Export macros reference v_suggestions at bind time. Seed replaces this stub
-- with the real projection; defining macros here keeps a single pdf_io load.
CREATE OR REPLACE VIEW v_suggestions AS
SELECT
    NULL::INTEGER AS id,
    NULL::INTEGER AS document_id,
    NULL::INTEGER AS page_no,
    NULL::DOUBLE AS x0,
    NULL::DOUBLE AS y0,
    NULL::DOUBLE AS x1,
    NULL::DOUBLE AS y1,
    NULL::VARCHAR AS text,
    NULL::VARCHAR AS context,
    NULL::INTEGER AS confidence,
    NULL::VARCHAR AS flag_tag,
    NULL::VARCHAR AS reason,
    NULL::INTEGER AS entity_id,
    NULL::VARCHAR AS source,
    NULL::TIMESTAMP AS created_at,
    NULL::VARCHAR AS status,
    NULL::VARCHAR AS band,
    NULL::VARCHAR AS kind,
    NULL::VARCHAR AS entity_text
WHERE false;

-- Foldable STRUCT list literal of accepted boxes for one document.
-- y is flipped: read_pdf_words is top-left origin; pdf_redact expects bottom-left.
CREATE OR REPLACE MACRO boxes_lit_for_doc(did) AS (
    SELECT coalesce(
        '[' || string_agg(
            '{page: ' || s.page_no ||
            ', x: ' || s.x0 ||
            ', y: ' || (p.height_pt - s.y1) ||
            ', w: ' || (s.x1 - s.x0) ||
            ', h: ' || (s.y1 - s.y0) || '}',
            ', '
            ORDER BY s.page_no, s.id
        ) || ']',
        '[]::STRUCT(page INTEGER, x DOUBLE, y DOUBLE, w DOUBLE, h DOUBLE)[]'
    )
    FROM v_suggestions s
    JOIN pages p ON p.document_id = s.document_id AND p.page_no = s.page_no
    WHERE s.document_id = did AND s.status = 'accepted'
);

-- Full UNION ALL pdf_redact SQL for a case from LIVE accepted boxes.
-- Callers (export_case_live / export_case_exec) hard-block when any flagged
-- remain pending — this macro assumes the case is clear and redacts all docs.
--
-- Note: do NOT call boxes_lit_for_doc(d.id) inside this string-agg — nested
-- correlated scalar macros collapse to the empty-box default. Inline the
-- accepted-box aggregate here so mid-session accepts appear in the plan SQL.
CREATE OR REPLACE MACRO build_export_sql(cid) AS (
    SELECT coalesce(string_agg(q, ' UNION ALL ' ORDER BY id), 'SELECT 0 AS document_id, 0 AS pages WHERE false')
    FROM (
        SELECT
            d.id,
            'SELECT ' || d.id || ' AS document_id, count(*)::INTEGER AS pages FROM pdf_redact(''' ||
            d.source_path || ''', ''exports/' || d.filename || '_redacted.pdf'', ' ||
            coalesce(
                (
                    SELECT '[' || string_agg(
                        '{page: ' || s.page_no ||
                        ', x: ' || s.x0 ||
                        ', y: ' || (p.height_pt - s.y1) ||
                        ', w: ' || (s.x1 - s.x0) ||
                        ', h: ' || (s.y1 - s.y0) || '}',
                        ', '
                        ORDER BY s.page_no, s.id
                    ) || ']'
                    FROM v_suggestions s
                    JOIN pages p ON p.document_id = s.document_id AND p.page_no = s.page_no
                    WHERE s.document_id = d.id AND s.status = 'accepted'
                ),
                '[]::STRUCT(page INTEGER, x DOUBLE, y DOUBLE, w DOUBLE, h DOUBLE)[]'
            ) || ')' AS q
        FROM documents d
        WHERE d.case_id = cid
    ) z
);

-- Dynamic SQL runner (quackapi constraint: table functions need foldable/literal SQL).
CREATE OR REPLACE MACRO run_sql(q) AS TABLE
SELECT * FROM query(q);

-- Meta for export: counts + plan SQL string (does not invoke pdf_redact).
-- P0-3: when any flagged remain, exported is 0 (hard block; no partial count).
-- When clear, exported = document count for the case (all docs redacted).
CREATE OR REPLACE MACRO export_case_exec(cid, act) AS TABLE
WITH
flagged AS (
    SELECT count(*)::INTEGER AS n
    FROM v_suggestions s
    JOIN documents d ON d.id = s.document_id
    WHERE d.case_id = cid AND s.band = 'flagged' AND s.status = 'pending'
),
docs AS (
    SELECT count(*)::INTEGER AS n
    FROM documents d
    WHERE d.case_id = cid
)
SELECT
    CASE WHEN (SELECT n FROM flagged) > 0 THEN 0 ELSE (SELECT n FROM docs) END AS exported,
    ((SELECT n FROM flagged) > 0) AS blocked,
    (SELECT n FROM flagged) AS flagged_remaining,
    -- When blocked, plan is a no-op so callers never see partial-doc SQL.
    CASE
        WHEN (SELECT n FROM flagged) > 0
        THEN 'SELECT 0 AS document_id, 0 AS pages WHERE false'
        ELSE build_export_sql(cid)
    END AS export_sql,
    coalesce(act, 'reviewer') AS actor_name,
    cid AS case_id;

-- export_case_live lives in routes/export.sql (hard-block + live run_sql).
