-- routes/provenance.sql — chain-of-custody HTTP surface.
-- GET /api/cases/:id/provenance[/recheck]  GET /api/documents/:id/provenance
-- :id is VARCHAR (case_no or document uuid). View re-hashes live each request.

CREATE OR REPLACE ROUTE api_case_provenance GET '/api/cases/:id/provenance' AS
SELECT * FROM v_case_provenance WHERE case_id = $id ORDER BY document_id;

CREATE OR REPLACE ROUTE api_case_provenance_recheck GET '/api/cases/:id/provenance/recheck' AS
SELECT * FROM v_case_provenance WHERE case_id = $id ORDER BY document_id;

CREATE OR REPLACE ROUTE api_doc_provenance GET '/api/documents/:id/provenance' AS
SELECT * FROM v_case_provenance WHERE cast(document_id AS VARCHAR) = $id;
