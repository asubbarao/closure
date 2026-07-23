.PHONY: install setup run test check clean

PORT ?= 8117
BASE  = http://127.0.0.1:$(PORT)

# Declarative SQL invariants (tests/dq_tests.json) run by dqtest over a freshly
# built model — no running server needed. Catches dead detector arms that an
# emptiness check cannot see (a UNION arm matching nothing still leaves its table
# non-empty). Needs a prior `make setup` (samples on disk).
check:
	@$$(./scripts/duckdb-bin.sh) :memory: -c ".read tests/check.sql"

# One-time: DuckDB on PATH + INSTALL quackapi FROM community.
install:
	./scripts/install.sh

# Sample PDF corpus + page PNG previews (hostfs + scalarfs + pdf_to_png).
# No host poppler/pdftoppm. Prefer DUCKDB_BIN ≥ 1.5.4 (brew). Optional:
#   PDF_EXTENSION=/path/to/font-bundled/pdf.duckdb_extension  (blank-PNG fix)
setup:
	./scripts/setup.sh

# Boot Closure ($(BASE)).
run:
	PORT=$(PORT) ./run.sh

# SQL invariants (dqtest) first, then fresh DB + Playwright e2e.
test: check
	@echo "==> e2e deps (npm + chromium if needed)"
	@cd tests/e2e && npm install --no-fund --no-audit && npx playwright install chromium
	@echo "==> fresh DB for deterministic e2e"
	@rm -f closure.db closure.db.wal
	@echo "==> fresh boot for test run"
	@mkdir -p .tmp
	@lsof -t -i tcp:$(PORT) -s tcp:LISTEN 2>/dev/null | xargs -r kill 2>/dev/null || true
	@for i in $$(seq 1 30); do \
		lsof -t -i tcp:$(PORT) -s tcp:LISTEN >/dev/null 2>&1 || break; \
		sleep 1; \
	done
	@PORT=$(PORT) nohup ./run.sh > .tmp/run.log 2>&1 & \
	for i in $$(seq 1 360); do \
		curl -s -o /dev/null -w '%{http_code}' $(BASE)/ 2>/dev/null | grep -q 200 && break; \
		sleep 1; \
	done; \
	curl -s -o /dev/null -w '%{http_code}' $(BASE)/ 2>/dev/null | grep -q 200 \
		|| { echo "boot failed — tail .tmp/run.log:"; tail -40 .tmp/run.log; exit 1; }
	cd tests/e2e && CLOSURE_BASE_URL=$(BASE) npx playwright test --reporter=line

clean:
	rm -f closure.db closure.db.wal
