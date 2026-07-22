-- auth.sql — quackapi auth (API key). OpenAPI stays at /docs · /openapi.json.
--
-- Default FOIA: open routes (no REQUIRE). Scheme always registered.
-- CLOSURE_API_KEY set → key stored (SHA-256). Lock a route with:
--   CREATE OR REPLACE ROUTE … REQUIRE closure_api AS …
-- JWT sketch:
--   CREATE AUTH closure_jwt AS JWT ( SECRET '…' );  -- $claims_sub as actor

CREATE OR REPLACE AUTH closure_api AS API_KEY;

SELECT * FROM quackapi_add_api_key(
    'closure_api',
    k,
    coalesce(nullif(getenv('USER'), ''), 'reviewer')
)
FROM (SELECT nullif(getenv('CLOSURE_API_KEY'), '') AS k)
WHERE k IS NOT NULL;

SELECT CASE
    WHEN nullif(getenv('CLOSURE_API_KEY'), '') IS NOT NULL
    THEN 'auth: API key registered — add REQUIRE closure_api to lock routes'
    ELSE 'auth: scheme ready; set CLOSURE_API_KEY to register a key (routes open)'
END AS auth_status;
