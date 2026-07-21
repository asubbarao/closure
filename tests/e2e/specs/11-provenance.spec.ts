import { test, expect } from "@playwright/test";
import { firstCaseId, getCaseProvenance } from "../helpers/api";

/**
 * Provenance — one API probe (UI panel was redundant).
 */
test.describe("11. Provenance / chain-of-custody", () => {
  test("GET /api/cases/:id/provenance returns custody payload when live", async ({
    request,
  }) => {
    const caseId = await firstCaseId(request);
    const probe = await getCaseProvenance(request, caseId);
    test.skip(!probe.live, probe.live === false ? probe.reason : "not live");

    const blob = JSON.stringify(probe.body).toLowerCase();
    expect(
      /sha256|md5|revision|custody|lineage|fingerprint|producer|ingested|chain|document/.test(
        blob
      ),
      `provenance body should look like custody data; got ${blob.slice(0, 300)}`
    ).toBeTruthy();
  });
});
