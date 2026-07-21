.PHONY: install setup run test clean

# Every knob derives from env with a committed default — nothing user-specific.
PORT ?= 8117
BASE  = http://127.0.0.1:$(PORT)

# One-time: download (or build) the quackapi DuckDB runtime into .deps/runtime.
# Graders: this is the only dependency step that is not pure Closure SQL/JS.
install:
	./scripts/install-runtime.sh

# Generate the sample PDF corpus + page PNG previews (idempotent).
# Auto-runs install-runtime if .deps/runtime is missing.
setup:
	./scripts/setup.sh

# Boot Closure fresh ($(BASE)). Requires install + setup once.
run:
	PORT=$(PORT) ./run.sh

# ALWAYS boot fresh, then run the Playwright e2e suite. Reusing a server that
# happens to be up means testing whatever stale code it booted with — never
# what's in the tree. run.sh kills any previous instance on the port and
# wipes the derived DB, so this is idempotent.
# Fresh clone: npm install + chromium once under tests/e2e (node_modules gitignored).
# Boot poll 360s — heavy remainder scan on the 110-page consolidated is ~3 min.
test:
	@echo "==> e2e deps (npm + chromium if needed)"
	@cd tests/e2e && npm install --no-fund --no-audit && npx playwright install chromium
	@echo "==> fresh boot for test run"
	@mkdir -p .tmp
	@PORT=$(PORT) nohup ./run.sh > .tmp/run.log 2>&1 & \
	for i in $$(seq 1 360); do \
		curl -s -o /dev/null -w '%{http_code}' $(BASE)/api/stats 2>/dev/null | grep -q 200 && break; \
		sleep 1; \
	done; \
	curl -s -o /dev/null -w '%{http_code}' $(BASE)/api/stats 2>/dev/null | grep -q 200 \
		|| { echo "boot failed — tail .tmp/run.log:"; tail -40 .tmp/run.log; exit 1; }
	cd tests/e2e && CLOSURE_BASE_URL=$(BASE) npx playwright test --reporter=line

# Remove generated runtime state: the DB, its WAL, and decision-log JSON
# files. Does not touch exports/.gitkeep, .deps/, or committed content.
clean:
	rm -f closure.db closure.db.wal
	rm -f exports/decisions/*.json
