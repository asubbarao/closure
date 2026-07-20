.PHONY: setup run test clean

# Generate the sample PDF corpus + page PNG previews (idempotent).
setup:
	./scripts/setup.sh

# Boot Closure fresh on the real quackapi extension (http://127.0.0.1:8117).
run:
	./run.sh

# Boot the app if it isn't already up, run the Playwright e2e suite against
# it, then leave the app running the way it was found.
test:
	@if curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8117/api/stats 2>/dev/null | grep -q 200; then \
		echo "==> app already up on :8117"; \
	else \
		echo "==> booting app for test run"; \
		nohup ./run.sh > /tmp/closure_run.log 2>&1 & \
		for i in $$(seq 1 30); do \
			curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8117/api/stats 2>/dev/null | grep -q 200 && break; \
			sleep 1; \
		done; \
	fi
	cd tests/e2e && npx playwright test --reporter=line

# Remove generated runtime state: the DB, its WAL, and decision-log JSON
# files. Does not touch exports/.gitkeep or any committed content.
clean:
	rm -f closure.db closure.db.wal
	rm -f exports/decisions/*.json
