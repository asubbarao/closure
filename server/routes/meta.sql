-- routes/meta.sql — the routes map, generated from the declarations.
--
-- quackapi exposes native route introspection (quackapi_routes() — a snapshot
-- of the live registry), so the map cannot drift from what actually serves.
-- source_file + leading-comment description are recovered by parsing the
-- CREATE ROUTE declarations themselves (read_text over the route modules)
-- and joined on route name — no hand-maintained list anywhere.
-- Dependencies: quackapi_routes(), server/*.sql + server/routes/*.sql on disk.

CREATE OR REPLACE VIEW v_routes AS
WITH decl_lines AS (
    SELECT
        regexp_replace(f.filename, '.*/', '') AS source_file,
        l.line_no,
        l.line
    FROM (
        SELECT filename, content FROM read_text('server/routes/*.sql')
        UNION ALL
        -- Top-level modules can declare routes too (e.g. pdf_io.sql scan APIs);
        -- this glob covers routes.sql and any future module-declared route.
        SELECT filename, content FROM read_text('server/*.sql')
    ) f,
    unnest(string_split(f.content, chr(10))) WITH ORDINALITY AS l(line, line_no)
),
with_prev AS (
    SELECT
        source_file,
        line_no,
        line,
        lag(line) OVER (PARTITION BY source_file ORDER BY line_no) AS prev_line
    FROM decl_lines
),
decls AS (
    SELECT
        source_file,
        line_no,
        prev_line,
        regexp_extract(
            line,
            'CREATE (?:OR REPLACE )?ROUTE\s+(\w+)\s+(GET|POST|PUT|DELETE|PATCH)\s+''([^'']+)''',
            ['name', 'method', 'pattern']
        ) AS d
    FROM with_prev
    WHERE regexp_matches(line, 'CREATE (?:OR REPLACE )?ROUTE\s')
),
described AS (
    SELECT
        d['name'] AS name,
        d['method'] AS method,
        d['pattern'] AS pattern,
        source_file,
        -- Leading comment line = description (box-drawing rules stripped).
        -- NULL retained when the declaration has no comment above it.
        CASE
            WHEN prev_line IS NOT NULL AND starts_with(trim(prev_line), '--')
            THEN nullif(
                trim(regexp_replace(trim(prev_line), '^--\s*─*\s*|\s*[─═]+\s*$', '', 'g')),
                ''
            )
            ELSE NULL
        END AS description
    FROM decls
)
SELECT
    r.name,
    r.method,
    r.pattern,
    r.status,
    r.require_auth,
    d.source_file,
    d.description
FROM quackapi_routes() r
LEFT JOIN described d ON d.name = r.name AND d.method = r.method;

-- Machine-readable route map (this route is itself a row in the map).
CREATE OR REPLACE ROUTE api_routes GET '/api/routes' AS
SELECT name, method, pattern, status, require_auth, source_file, description
FROM v_routes
ORDER BY pattern, method;
