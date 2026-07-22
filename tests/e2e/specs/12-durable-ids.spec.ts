import { test, expect } from "@playwright/test";
import { execFileSync } from "node:child_process";
import * as fs from "node:fs";
import * as path from "node:path";
import {
  getDocSuggestions,
  pickReviewDoc,
  postDecision,
  waitForSuggestionStatus,
} from "../helpers/api";

/**
 * Durable subject keys (data-model fix): decision rebind + offline two-boot
 * document id stability. Complements UI flows without depending on DOM queue.
 */

const REPO = path.resolve(__dirname, "../../..");
// Same resolution order as run.sh: env → .deps/runtime → sibling checkout.
const DUCKDB =
  process.env.DUCKDB_BIN ||
  [
    path.resolve(REPO, ".deps/runtime/duckdb"),
    path.resolve(REPO, "../quackapi/build/release/duckdb"),
  ].find((p) => fs.existsSync(p))!;

function offlineBootIds(dbPath: string, outCsv: string) {
  // Chain via shell so .read works (duckdb -c rejects .read meta-commands)
  const script = `
set -e
cd ${JSON.stringify(REPO)}
rm -f ${JSON.stringify(dbPath)} ${JSON.stringify(dbPath)}.wal
${JSON.stringify(DUCKDB)} -unsigned ${JSON.stringify(dbPath)} <<'SQL'
.read server/config.sql
SET variable samples_dir = (SELECT value FROM app_config WHERE key = 'samples_dir');
SET variable exports_dir = (SELECT value FROM app_config WHERE key = 'exports_dir');
SET variable static_dir = '.';
SET variable port = '8117';
.read server/extensions.sql
.read server/store.sql
.read server/raw/sources.sql
.read server/typed/sources.sql
.read server/domain/facts.sql
COPY (SELECT cast(id AS VARCHAR) AS id, filename FROM documents ORDER BY filename)
  TO '${outCsv.replace(/'/g, "")}' (HEADER, OVERWRITE true);
SQL
`;
  execFileSync("/bin/bash", ["-c", script], {
    stdio: ["ignore", "pipe", "pipe"],
    timeout: 180_000,
  });
}

test.describe("12. Durable ids + decision API", () => {
  test("POST decision flips status on API without DOM", async ({ request }) => {
    const doc = await pickReviewDoc(request);
    const pending = (await getDocSuggestions(request, doc.id)).filter(
      (s) => s.status === "pending"
    );
    test.skip(pending.length === 0, "no pending suggestions");

    const target =
      pending.find((s) => s.band === "high") ||
      pending.find((s) => s.band === "review") ||
      pending[0];

    const res = await postDecision(
      request,
      target.id,
      "accepted",
      "api-accept-no-dom"
    );
    expect(
      res.ok() || res.status() === 200,
      `POST decision → ${res.status()}`
    ).toBeTruthy();

    const live = await waitForSuggestionStatus(
      request,
      doc.id,
      target.id,
      "accepted"
    );
    expect(live?.status).toBe("accepted");
    // id shape: durable md5 hex of the natural key (opaque 32-char string)
    expect(String(target.id)).toMatch(/^[0-9a-f]{32}$/i);
  });

  test("document ids identical across two offline boots", async () => {
    test.skip(
      !fs.existsSync(DUCKDB),
      `quackapi duckdb binary missing at ${DUCKDB}`
    );

    const a = `/tmp/closure_e2e_docs_a_${process.pid}.csv`;
    const b = `/tmp/closure_e2e_docs_b_${process.pid}.csv`;
    const dba = `/tmp/closure_e2e_a_${process.pid}.db`;
    const dbb = `/tmp/closure_e2e_b_${process.pid}.db`;
    for (const p of [a, b, dba, dbb, `${dba}.wal`, `${dbb}.wal`]) {
      try {
        fs.unlinkSync(p);
      } catch {
        /* ignore */
      }
    }

    offlineBootIds(dba, a);
    offlineBootIds(dbb, b);

    const ca = fs.readFileSync(a, "utf8").trim();
    const cb = fs.readFileSync(b, "utf8").trim();
    expect(ca.length).toBeGreaterThan(20);
    expect(ca).toBe(cb);
  });
});
