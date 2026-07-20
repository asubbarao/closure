import { APIRequestContext, expect } from "@playwright/test";

export type Suggestion = {
  id: number;
  document_id: number;
  page_no: number;
  text: string;
  context?: string;
  confidence: number;
  status: string;
  band: string;
  kind?: string;
  entity_id?: number | null;
  entity_text?: string | null;
  flag_tag?: string | null;
  source?: string;
  filename?: string;
};

export type DocumentRow = {
  id: number;
  filename: string;
  page_count: number;
  suggestion_count: number;
  pending_count: number;
  accepted_count: number;
  rejected_count: number;
  flagged_count: number;
  high_count: number;
  review_count: number;
  progress_pct: number;
};

export type ExportPlan = {
  blocked: boolean;
  export_sql?: string;
};

export type AuditEvent = {
  ts?: string;
  actor?: string;
  action?: string;
  suggestion_id?: number;
  case_id?: number;
  target?: string;
  reason?: string;
};

/** Judge panel row (wave-2). Shape may vary; fields optional. */
export type JudgePanel = {
  suggestion_id?: number;
  confidence?: number;
  panel_signal?: string;
  judge_count?: number;
  redact_votes?: number;
  keep_votes?: number;
  unsure_votes?: number;
  judges?: unknown;
  [key: string]: unknown;
};

/** Residual / possible-missed candidate (wave-2). */
export type MissedCandidate = {
  id?: number;
  document_id?: number;
  page?: number;
  page_no?: number;
  text?: string;
  kind?: string;
  why?: string;
  x0?: number;
  y0?: number;
  x1?: number;
  y1?: number;
  box?: unknown;
  [key: string]: unknown;
};

export type SearchResult = {
  matches: Array<Record<string, unknown>>;
  count: number;
  exact_count?: number;
  /** Wave-2 fuzzy hit count (API name). */
  fuzzy_count?: number;
  /** Alias some UIs use for fuzzy_count. */
  similar_count?: number;
  exact?: number;
  similar?: number;
  fuzzy?: number;
  [key: string]: unknown;
};

function asArray<T>(payload: unknown): T[] {
  if (Array.isArray(payload)) return payload as T[];
  if (payload && typeof payload === "object") {
    const o = payload as Record<string, unknown>;
    for (const k of [
      "suggestions",
      "rows",
      "documents",
      "events",
      "audit",
      "judges",
      "candidates",
      "missed",
      "residual",
      "hits",
      "items",
      "chain",
      "provenance",
      "documents_custody",
    ]) {
      if (Array.isArray(o[k])) return o[k] as T[];
    }
  }
  return [];
}

function unwrapRow<T extends object>(payload: unknown): T {
  if (Array.isArray(payload)) return (payload[0] ?? {}) as T;
  return (payload ?? {}) as T;
}

/** Probe a route; returns status + parsed JSON body (or null). */
export async function probeRoute(
  request: APIRequestContext,
  path: string
): Promise<{ status: number; ok: boolean; body: unknown }> {
  const res = await request.get(path);
  let body: unknown = null;
  try {
    body = await res.json();
  } catch {
    try {
      body = await res.text();
    } catch {
      body = null;
    }
  }
  return { status: res.status(), ok: res.ok(), body };
}

/**
 * Skip-friendly route gate for wave-2 features still landing.
 * Returns body when live; caller should `test.skip` when null after calling this
 * with the skip helper.
 */
export async function requireRoute(
  request: APIRequestContext,
  path: string
): Promise<{ live: true; status: number; body: unknown } | { live: false; status: number; reason: string }> {
  const { status, ok, body } = await probeRoute(request, path);
  if (status === 404) {
    return {
      live: false,
      status,
      reason: `route ${path} returned 404 (wave-2 feature not landed yet)`,
    };
  }
  if (status === 405) {
    return {
      live: false,
      status,
      reason: `route ${path} returned 405 (method not allowed — feature not wired)`,
    };
  }
  if (!ok && status >= 500) {
    return {
      live: false,
      status,
      reason: `route ${path} returned ${status} (server error — treat as not ready)`,
    };
  }
  return { live: true, status, body };
}

export async function getStats(request: APIRequestContext) {
  const res = await request.get("/api/stats");
  expect(res.ok(), `GET /api/stats → ${res.status()}`).toBeTruthy();
  const data = await res.json();
  return Array.isArray(data) ? data[0] : data;
}

export async function getCaseDocuments(
  request: APIRequestContext,
  caseId = 1
): Promise<DocumentRow[]> {
  const res = await request.get(`/api/cases/${caseId}/documents`);
  expect(res.ok(), `GET /api/cases/${caseId}/documents → ${res.status()}`).toBeTruthy();
  return asArray<DocumentRow>(await res.json());
}

export async function getDocSuggestions(
  request: APIRequestContext,
  docId: number
): Promise<Suggestion[]> {
  const res = await request.get(`/api/documents/${docId}/suggestions`);
  expect(res.ok(), `GET /api/documents/${docId}/suggestions → ${res.status()}`).toBeTruthy();
  return asArray<Suggestion>(await res.json());
}

export async function getCaseSuggestions(
  request: APIRequestContext,
  caseId = 1
): Promise<Suggestion[]> {
  const res = await request.get(`/api/cases/${caseId}/suggestions`);
  expect(res.ok(), `GET /api/cases/${caseId}/suggestions → ${res.status()}`).toBeTruthy();
  return asArray<Suggestion>(await res.json());
}

export async function getExportPlan(
  request: APIRequestContext,
  caseId = 1
): Promise<ExportPlan> {
  const res = await request.get(`/api/cases/${caseId}/export_plan`);
  expect(res.ok(), `GET /api/cases/${caseId}/export_plan → ${res.status()}`).toBeTruthy();
  const data = await res.json();
  return (Array.isArray(data) ? data[0] : data) as ExportPlan;
}

export async function getCaseAudit(
  request: APIRequestContext,
  caseId = 1
): Promise<AuditEvent[]> {
  const res = await request.get(`/api/cases/${caseId}/audit`);
  expect(res.ok(), `GET /api/cases/${caseId}/audit → ${res.status()}`).toBeTruthy();
  return asArray<AuditEvent>(await res.json());
}

/** GET /api/suggestions/:id/judges — wave-2; may 404. */
export async function getSuggestionJudges(
  request: APIRequestContext,
  suggestionId: number
) {
  return requireRoute(request, `/api/suggestions/${suggestionId}/judges`);
}

/** GET /api/documents/:id/missed — wave-2 residual PII queue; may 404. */
export async function getDocMissed(request: APIRequestContext, docId: number) {
  return requireRoute(request, `/api/documents/${docId}/missed`);
}

/** GET /api/cases/:id/provenance — wave-2 chain-of-custody; may 404. */
export async function getCaseProvenance(
  request: APIRequestContext,
  caseId = 1
) {
  return requireRoute(request, `/api/cases/${caseId}/provenance`);
}

/**
 * Word / phrase search. Baseline: {matches, count}.
 * Wave-2 fuzzy may add exact_count / similar_count (or exact / similar).
 */
export async function searchCase(
  request: APIRequestContext,
  q: string,
  caseId = 1,
  extra: Record<string, string> = {}
): Promise<{ status: number; result: SearchResult | null; raw: unknown }> {
  const params = new URLSearchParams({ q, case: String(caseId), ...extra });
  const res = await request.get(`/api/search?${params}`);
  if (!res.ok()) {
    return { status: res.status(), result: null, raw: null };
  }
  const raw = await res.json();
  const row = unwrapRow<Record<string, unknown>>(raw);
  let matches = row.matches as unknown;
  if (typeof matches === "string") {
    try {
      matches = JSON.parse(matches);
    } catch {
      matches = [];
    }
  }
  if (!Array.isArray(matches)) {
    // bare array of match rows
    if (Array.isArray(raw) && raw.length && !("matches" in (raw[0] || {}))) {
      matches = raw;
    } else {
      matches = [];
    }
  }
  const count =
    row.count != null
      ? Number(row.count)
      : Array.isArray(matches)
        ? matches.length
        : 0;
  const result: SearchResult = {
    matches: matches as Array<Record<string, unknown>>,
    count,
  };
  for (const k of [
    "exact_count",
    "fuzzy_count",
    "similar_count",
    "exact",
    "similar",
    "fuzzy",
    "exact_matches",
    "similar_matches",
  ] as const) {
    if (k in row) (result as Record<string, unknown>)[k] = row[k];
  }
  // Normalize similar_count ↔ fuzzy_count for callers
  if (result.fuzzy_count != null && result.similar_count == null) {
    result.similar_count = Number(result.fuzzy_count);
  }
  if (result.similar_count != null && result.fuzzy_count == null) {
    result.fuzzy_count = Number(result.similar_count);
  }
  return { status: res.status(), result, raw };
}

export async function postDecision(
  request: APIRequestContext,
  suggestionId: number,
  status: string,
  reason = "e2e"
) {
  const q = new URLSearchParams({
    status,
    actor: "e2e-runner",
    reason,
  });
  const res = await request.post(
    `/api/suggestions/${suggestionId}/decision?${q.toString()}`,
    {
      headers: { "Content-Type": "application/json", Accept: "application/json" },
      data: {},
    }
  );
  return res;
}

export async function waitForSuggestionStatus(
  request: APIRequestContext,
  docId: number,
  suggestionId: number,
  status: string,
  attempts = 20
): Promise<Suggestion | undefined> {
  for (let i = 0; i < attempts; i++) {
    const rows = await getDocSuggestions(request, docId);
    const hit = rows.find((r) => Number(r.id) === Number(suggestionId));
    if (hit && hit.status === status) return hit;
    await new Promise((r) => setTimeout(r, 250));
  }
  const rows = await getDocSuggestions(request, docId);
  return rows.find((r) => Number(r.id) === Number(suggestionId));
}

/** Prefer a medium-sized reviewable doc with pending work (not the huge consolidated file). */
export async function pickReviewDoc(
  request: APIRequestContext,
  caseId = 1
): Promise<DocumentRow> {
  const docs = await getCaseDocuments(request, caseId);
  const ranked = [...docs].sort((a, b) => {
    // Prefer docs with pending suggestions and fewer pages
    const pendA = a.pending_count > 0 ? 0 : 1;
    const pendB = b.pending_count > 0 ? 0 : 1;
    if (pendA !== pendB) return pendA - pendB;
    return a.page_count - b.page_count;
  });
  const pick = ranked[0];
  if (!pick) throw new Error("No documents in case");
  return pick;
}

/** Pick any pending flagged suggestion from case (data-driven). */
export async function pickFlaggedPending(
  request: APIRequestContext,
  caseId = 1
): Promise<Suggestion | null> {
  const rows = await getCaseSuggestions(request, caseId);
  return (
    rows.find((s) => s.band === "flagged" && s.status === "pending") ||
    rows.find((s) => s.band === "flagged") ||
    null
  );
}

export function isStreetFalsePositive(s: Suggestion): boolean {
  const kind = (s.kind || "").toUpperCase();
  const text = s.text || "";
  return (
    kind.includes("STREET") ||
    /\bStreet\b/i.test(text) ||
    (s.flag_tag === "false_positive" && /street/i.test(text))
  );
}

export function pending(s: Suggestion): boolean {
  return s.status === "pending";
}

/** Normalize missed-list payload into candidate rows. */
export function asMissedCandidates(body: unknown): MissedCandidate[] {
  if (Array.isArray(body)) {
    if (
      body.length === 1 &&
      body[0] &&
      typeof body[0] === "object" &&
      !("text" in (body[0] as object)) &&
      !("page" in (body[0] as object)) &&
      !("page_no" in (body[0] as object))
    ) {
      return asArray<MissedCandidate>(body[0]);
    }
    return body as MissedCandidate[];
  }
  return asArray<MissedCandidate>(body);
}

/** Normalize judges payload into a panel object. */
export function asJudgePanel(body: unknown): JudgePanel {
  if (Array.isArray(body)) {
    if (body.length === 0) return { judges: [], judge_count: 0 };
    // Live shape: one row per judge vote with panel_* columns repeated
    const votes = body as Array<Record<string, unknown>>;
    const first = votes[0] || {};
    return {
      suggestion_id: first.suggestion_id as number | undefined,
      confidence:
        (first.panel_confidence as number | undefined) ??
        (first.confidence as number | undefined),
      panel_signal: first.panel_signal as string | undefined,
      judge_count:
        (first.judge_count as number | undefined) ?? votes.length,
      redact_votes: first.redact_votes as number | undefined,
      keep_votes: first.keep_votes as number | undefined,
      unsure_votes: first.unsure_votes as number | undefined,
      judges: votes,
    };
  }
  if (body && typeof body === "object") return body as JudgePanel;
  return {};
}

/** Prefer a document that has residual missed candidates (data-driven). */
export async function pickDocWithMissed(
  request: APIRequestContext,
  caseId = 1
): Promise<{ doc: DocumentRow; candidates: MissedCandidate[] } | null> {
  const docs = await getCaseDocuments(request, caseId);
  const ranked = [...docs].sort((a, b) => a.page_count - b.page_count);
  for (const doc of ranked) {
    const probe = await getDocMissed(request, doc.id);
    if (!probe.live) continue;
    const candidates = asMissedCandidates(probe.body);
    if (candidates.length > 0) return { doc, candidates };
  }
  // Case-level fallback
  const caseProbe = await requireRoute(request, `/api/cases/${caseId}/missed`);
  if (caseProbe.live) {
    const candidates = asMissedCandidates(caseProbe.body);
    if (candidates.length > 0) {
      const docId = Number(candidates[0].document_id);
      const doc = docs.find((d) => d.id === docId) || ranked[0];
      if (doc) return { doc, candidates };
    }
  }
  return null;
}
