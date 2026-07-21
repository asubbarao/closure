.PHONY: setup run test clean

# Every knob derives from env with a committed default — nothing user-specific.
PORT ?= 8117
BASE  = http://127.0.0.1:$(PORT)

# Generate the sample PDF corpus + page PNG previews (idempotent).
setup:
	./scripts/setup.sh

# Boot Closure fresh on the real quackapi extension ($(BASE)).
run:
	PORT=$(PORT) ./run.sh

# ALWAYS boot fresh, then run the Playwright e2e suite. Reusing a server that
# happens to be up means testing whatever stale code it booted with — never
# what's in the tree. run.sh kills any previous instance on the port and
# wipes the derived DB, so this is idempotent.
test:
	@echo "==> fresh boot for test run"
	@mkdir -p .tmp
	@PORT=$(PORT) nohup ./run.sh > .tmp/run.log 2>&1 & \
	for i in $$(seq 1 240); do \
		curl -s -o /dev/null -w '%{http_code}' $(BASE)/api/stats 2>/dev/null | grep -q 200 && break; \
		sleep 1; \
	done; \
	curl -s -o /dev/null -w '%{http_code}' $(BASE)/api/stats 2>/dev/null | grep -q 200 \
		|| { echo "boot failed — tail .tmp/run.log:"; tail -30 .tmp/run.log; exit 1; }
	cd tests/e2e && CLOSURE_BASE_URL=$(BASE) npx playwright test --reporter=line

# Remove generated runtime state: the DB, its WAL, and decision-log JSON
# files. Does not touch exports/.gitkeep or any committed content.
clean:
	rm -f closure.db closure.db.wal
	rm -f exports/decisions/*.json
