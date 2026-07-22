/**
 * Closure — review workspace organized around the TRIAGE FUNNEL.
 *
 * Funnel: total → auto-passable (high-conf ≥ threshold, never flagged) → residual.
 * Residual is GROUPED (entity / kind / pattern) for batch judgment.
 * Unit of work = GROUP. Keyboard-first. Progress = "N resolved · M residual left".
 *
 * APIs:
 *   GET  /api/cases/:id/triage?threshold=
 *   GET  /api/cases/:id/triage/groups?threshold=&scope=&doc_id=
 *   POST /api/cases/:id/triage/accept-high?threshold=
 *   POST /api/cases/:id/triage/group/decision?group_key=&status=&exclude_ids=
 *   POST /api/suggestions/:id/decision  (single instance)
 *   POST /api/suggestions/batch/decision (multi-select)
 */
(function () {
  "use strict";

  const C = window.Closure;
  const ACTOR = C.DEFAULT_ACTOR;
  const STATUS_CLASS = ["pending", "accepted", "rejected", "flagged"];
  const THR_DEFAULT = 90;

  const body = document.body;
  const boot = C.readBoot();
  const docId = boot.docId || body.dataset.docId;
  const caseId = boot.caseId || body.dataset.caseId;
  const pageNo = Number(boot.pageNo || body.dataset.pageNo);
  const pageCount = Number(boot.pageCount || body.dataset.pageCount);
  const actor = boot.actor || body.dataset.actor || ACTOR;
  const scale = Number(boot.scale || body.dataset.scale || 1);

  const els = {
    qList: document.getElementById("q-list"),
    stage: document.getElementById("stage"),
    page: document.getElementById("pdf-page"),
    marks: document.getElementById("marks-layer"),
    progressLabel: document.getElementById("progress-label"),
    progressBar: document.getElementById("progress-bar"),
    pendingLabel: document.getElementById("pending-label"),
    bandHigh: document.getElementById("band-high"),
    bandReview: document.getElementById("band-review"),
    bandFlagged: document.getElementById("band-flagged"),
    toastHost: document.getElementById("toast-host"),
    bandFilters: document.getElementById("band-filters"),
    bulkSel: document.getElementById("bulk-sel"),
    bulkCount: document.getElementById("bulk-count"),
    bulkMeta: document.getElementById("bulk-meta"),
    btnBulkAccept: document.getElementById("btn-bulk-accept"),
    btnBulkReject: document.getElementById("btn-bulk-reject"),
    flagExcl: document.getElementById("flag-excl"),
    flagExclN: document.getElementById("flag-excl-n"),
    // funnel
    funnelTotal: document.getElementById("funnel-total"),
    funnelAuto: document.getElementById("funnel-auto"),
    funnelResidual: document.getElementById("funnel-residual"),
    funnelThrLabel: document.getElementById("funnel-thr-label"),
    funnelProgress: document.getElementById("funnel-progress-text"),
    thrSlider: document.getElementById("thr-slider"),
    thrVal: document.getElementById("thr-val"),
    btnAcceptHigh: document.getElementById("btn-accept-high"),
    btnAcceptHighN: document.getElementById("btn-accept-high-n"),
    scopeLabel: document.getElementById("funnel-scope-label"),
    residualLabel: document.getElementById("residual-section-label"),
  };

  /** @type {Array} document-scoped suggestions (marks + page queue seed) */
  let suggestions = [];
  /** @type {object|null} funnel snapshot */
  let funnel = null;
  /** @type {Array} residual groups from triage API */
  let residualGroups = [];
  /** group cursor index in residualGroups */
  let groupCursor = 0;
  /** instance cursor within open group (for a/r) */
  let instCursor = 0;
  /** per-group Set of excluded instance ids */
  const groupExceptions = new Map();
  /** selected ids for legacy multi-select bar */
  const selected = new Set();
  let lastSelIdx = -1;
  const bandsOn = { high: true, review: true, flagged: true };
  let threshold = THR_DEFAULT;
  // Document scope is the default on the review page — residual is the work
  // for THIS file. Case-wide grouping is one click away via the scope toggle.
  let scope = "doc"; // case | doc
  let pendingOnly = true;
  const undoStack = [];
  const inflight = new Set();
  let lastToastTimer = null;
  let bulkBusy = false;
  let thrDebounce = null;
  /** @type {Array} current page visual lines (document_lines) */
  let pageLines = [];
  let currentLineNo = null;
  let railMode = "files"; // files | lines

  // ── helpers ───────────────────────────────────────────────────────────
  const bandOf = C.bandOf;
  const confClass = C.confClass;
  const isFlagged = C.isFlagged;
  const escapeHtml = C.escapeHtml;
  const highlightContext = C.highlightContext;

  function markVisualStatus(s) {
    if (s.status === "accepted") return "accepted";
    if (s.status === "rejected") return "rejected";
    if (s.band === "flagged" || Number(s.confidence) < 60) return "flagged";
    return "pending";
  }

  function isAutoEligible(s) {
    return (
      s.status === "pending" &&
      Number(s.confidence) >= threshold &&
      !isFlagged(s) &&
      (s.flag_tag || "") !== "false_positive"
    );
  }

  function isEligible(s) {
    return s.status === "pending" && !isFlagged(s);
  }

  function shortText(t) {
    const s = String(t || "");
    return s.length > 28 ? s.slice(0, 26) + "…" : s;
  }

  function findById(id) {
    return suggestions.find((s) => s.id === id);
  }

  function exceptionsFor(groupKey) {
    if (!groupExceptions.has(groupKey)) groupExceptions.set(groupKey, new Set());
    return groupExceptions.get(groupKey);
  }

  function groupIds(g) {
    if (Array.isArray(g.instances) && g.instances.length) {
      return g.instances.map((i) => i.id);
    }
    if (g.ids) {
      return String(g.ids)
        .split(",")
        .map((x) => trimStr(x))
        .filter((id) => id);
    }
    return [];
  }

  function trimStr(s) {
    return String(s || "").replace(/^\s+|\s+$/g, "");
  }

  function activeIds(g) {
    const excl = exceptionsFor(g.group_key);
    return groupIds(g).filter((id) => !excl.has(id));
  }

  // ── normalize ─────────────────────────────────────────────────────────
  function normalizeApiRow(r) {
    const conf = Number(r.confidence != null ? r.confidence : r.conf);
    const status = r.status || "pending";
    const band = bandOf(conf, r.band);
    const left =
      r.left_px != null
        ? Number(r.left_px)
        : r.x0 != null
          ? Number(r.x0) * scale
          : undefined;
    const top =
      r.top_px != null
        ? Number(r.top_px)
        : r.y0 != null
          ? Number(r.y0) * scale
          : undefined;
    const width =
      r.width != null
        ? Number(r.width)
        : r.x0 != null && r.x1 != null
          ? (Number(r.x1) - Number(r.x0)) * scale
          : undefined;
    const height =
      r.height != null
        ? Number(r.height)
        : r.y0 != null && r.y1 != null
          ? (Number(r.y1) - Number(r.y0)) * scale
          : undefined;
    return {
      id: r.id,
      text: r.text || r.matched_text || "",
      context: r.context || "",
      confidence: conf,
      page_no: Number(r.page_no != null ? r.page_no : r.page),
      line_no: r.line_no != null ? Number(r.line_no) : null,
      status,
      band,
      entity_id: r.entity_id != null ? r.entity_id : null,
      entity_text: r.entity_text || r.canonical_text || "",
      kind: r.kind || "",
      flag_tag: r.flag_tag || "",
      reason: r.reason || "",
      document_id: r.document_id != null ? r.document_id : docId,
      x0: r.x0 != null ? Number(r.x0) : undefined,
      y0: r.y0 != null ? Number(r.y0) : undefined,
      x1: r.x1 != null ? Number(r.x1) : undefined,
      y1: r.y1 != null ? Number(r.y1) : undefined,
      left_px: left,
      top_px: top,
      width,
      height,
    };
  }

  function extractRows(payload) {
    return C.asRows(payload);
  }

  function extractOne(payload) {
    if (Array.isArray(payload)) return payload[0] || null;
    if (payload && typeof payload === "object") return payload;
    return null;
  }

  function normalizeGroup(g) {
    let instances = g.instances;
    if (typeof instances === "string") {
      try {
        instances = JSON.parse(instances);
      } catch (_) {
        instances = [];
      }
    }
    if (!Array.isArray(instances)) instances = [];
    return {
      group_key: g.group_key,
      group_label: g.group_label || g.group_key,
      kind: g.kind || "",
      entity_id: g.entity_id != null ? g.entity_id : null,
      n: Number(g.n || instances.length || 0),
      doc_count: Number(g.doc_count || 0),
      page_count: Number(g.page_count || 0),
      min_conf: Number(g.min_conf || 0),
      max_conf: Number(g.max_conf || 0),
      has_flagged: !!g.has_flagged,
      has_fp: !!g.has_fp,
      sample_reason: g.sample_reason || "",
      ids: g.ids || "",
      group_band: g.group_band || (g.has_flagged ? "flagged" : "review"),
      instances: instances.map((i) => ({
        id: i.id,
        document_id: i.document_id,
        filename: i.filename || "",
        page_no: Number(i.page_no),
        line_no: i.line_no != null ? Number(i.line_no) : null,
        text: i.text || "",
        context: i.context || "",
        confidence: Number(i.confidence),
        band: i.band || bandOf(i.confidence),
      })),
    };
  }

  function readDomSuggestions() {
    const root = document.getElementById("ssr-seed") || els.qList;
    const nodes = root ? root.querySelectorAll(".sugg[data-id]") : [];
    const out = [];
    nodes.forEach((n) => {
      out.push({
        id: n.dataset.id,
        text: n.dataset.text || "",
        context: n.dataset.context || "",
        confidence: Number(n.dataset.conf),
        page_no: Number(n.dataset.page),
        line_no: n.dataset.line != null ? Number(n.dataset.line) : null,
        status: n.dataset.status || "pending",
        band: bandOf(n.dataset.conf, n.dataset.band),
        entity_id: n.dataset.entityId || null,
        entity_text: n.dataset.entityText || "",
        kind: n.dataset.kind || "",
        flag_tag: n.dataset.flagTag || "",
      });
    });
    return out;
  }

  // ── network ───────────────────────────────────────────────────────────
  async function fetchLiveSuggestions() {
    try {
      const res = await fetch("/api/documents/" + docId + "/suggestions", {
        headers: { Accept: "application/json" },
      });
      if (!res.ok) return false;
      const data = await res.json();
      const rows = extractRows(data).map(normalizeApiRow).filter((s) => s.id);
      if (!rows.length) return false;
      const byId = new Map(rows.map((r) => [r.id, r]));
      if (suggestions.length) {
        suggestions = suggestions.map((s) => {
          const live = byId.get(s.id);
          return live ? Object.assign({}, s, live) : s;
        });
        const have = new Set(suggestions.map((s) => s.id));
        rows.forEach((r) => {
          if (!have.has(r.id)) suggestions.push(r);
        });
      } else {
        suggestions = rows;
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  /** Fold tall triage rows {funnel,status,band,n} into one funnel object. */
  function foldTriageTall(rows) {
    const f = {
      case_id: caseId,
      threshold: threshold,
      total: 0,
      resolved: 0,
      pending: 0,
      auto_passable: 0,
      residual: 0,
      high_pending: 0,
      review_pending: 0,
      flagged_pending: 0,
      progress_pct: 0,
    };
    (rows || []).forEach(function (r) {
      const n = Number(r.n || 0);
      f.total += n;
      if (r.status === "accepted" || r.status === "rejected") f.resolved += n;
      if (r.status === "pending") f.pending += n;
      if (r.funnel === "auto") f.auto_passable += n;
      if (r.funnel === "residual") f.residual += n;
      if (r.status === "pending" && r.band === "high") f.high_pending += n;
      if (r.status === "pending" && r.band === "review") f.review_pending += n;
      if (r.status === "pending" && r.band === "flagged") f.flagged_pending += n;
    });
    f.progress_pct =
      f.total === 0 ? 0 : Math.round((100.0 * f.resolved) / f.total);
    return f;
  }

  async function fetchFunnel() {
    try {
      const res = await fetch(
        "/api/cases/" + caseId + "/triage?threshold=" + threshold,
        { headers: { Accept: "application/json" } }
      );
      if (!res.ok) return false;
      const data = await res.json();
      // Prefer tall fold; tolerate legacy one-row wide shape.
      const rows = extractRows(data);
      if (rows.length && rows[0].funnel != null && rows[0].n != null) {
        funnel = foldTriageTall(rows);
      } else {
        funnel = extractOne(data);
      }
      return !!funnel;
    } catch (_) {
      return false;
    }
  }

  /**
   * When residual groups are empty but this document still has pending
   * suggestions (typically high-conf auto-passable), surface them as a
   * synthetic queue group so conf/band filters and a/r still work.
   */
  function syntheticPendingGroup() {
    const pending = suggestions.filter(
      (s) => s.status === "pending" && (s.document_id || docId) === docId
    );
    if (!pending.length) return null;
    const insts = pending.map((s) => ({
      id: s.id,
      document_id: s.document_id || docId,
      filename: s.filename || "",
      page_no: s.page_no,
      text: s.text,
      context: s.context || "",
      confidence: Number(s.confidence),
      band: s.band || bandOf(s.confidence),
      status: s.status || "pending",
    }));
    const confs = insts.map((i) => i.confidence);
    const hasFlagged = insts.some((i) => i.band === "flagged");
    return {
      group_key: "pending:doc:" + docId,
      group_label: "Document pending",
      kind: "pending",
      entity_id: null,
      n: insts.length,
      doc_count: 1,
      page_count: new Set(insts.map((i) => i.page_no)).size,
      min_conf: Math.min.apply(null, confs),
      max_conf: Math.max.apply(null, confs),
      has_flagged: hasFlagged,
      has_fp: false,
      sample_reason: "Remaining pending on this document (incl. auto-passable high-conf)",
      ids: insts.map((i) => i.id).join(","),
      group_band: hasFlagged ? "flagged" : insts.some((i) => i.band === "review") ? "review" : "high",
      instances: insts,
    };
  }

  async function fetchGroups() {
    try {
      const q =
        "/api/cases/" +
        caseId +
        "/triage/groups?threshold=" +
        threshold +
        "&scope=" +
        encodeURIComponent(scope) +
        "&doc_id=" +
        (scope === "doc" ? docId : 0);
      const res = await fetch(q, { headers: { Accept: "application/json" } });
      if (!res.ok) return false;
      const data = await res.json();
      residualGroups = extractRows(data).map(normalizeGroup).filter((g) => g.group_key);
      // Drop groups fully band-filtered out
      residualGroups = residualGroups.filter((g) => {
        if (!g.instances.length) return bandsOn[g.group_band] !== false;
        return g.instances.some((i) => bandsOn[i.band] !== false);
      });
      // Fallback: residual drained but document still has pending work.
      if (!residualGroups.length) {
        const syn = syntheticPendingGroup();
        if (syn) residualGroups = [syn];
      }
      if (groupCursor >= residualGroups.length) groupCursor = Math.max(0, residualGroups.length - 1);
      return true;
    } catch (_) {
      return false;
    }
  }

  async function postDecision(id, status, reason) {
    const params = new URLSearchParams();
    params.set("status", status);
    params.set("actor", actor);
    if (reason) params.set("reason", reason);
    return C.postJson("/api/suggestions/" + id + "/decision?" + params.toString());
  }

  async function postBatch(ids, status, reason) {
    if (!ids.length) return { ok: true, count: 0 };
    const params = new URLSearchParams();
    params.set("status", status);
    params.set("ids", ids.join(","));
    params.set("actor", actor);
    if (reason) params.set("reason", reason);
    return C.postJson("/api/suggestions/batch/decision?" + params.toString());
  }

  async function postAcceptHigh() {
    const params = new URLSearchParams();
    params.set("threshold", String(threshold));
    params.set("actor", actor);
    params.set("reason", "triage high-confidence auto-pass ≥" + threshold);
    return C.postJson("/api/cases/" + caseId + "/triage/accept-high?" + params.toString());
  }

  async function postGroupDecision(groupKey, status, excludeIds, reason) {
    const params = new URLSearchParams();
    params.set("group_key", groupKey);
    params.set("status", status);
    params.set("threshold", String(threshold));
    params.set("actor", actor);
    params.set("exclude_ids", (excludeIds || []).join(","));
    if (reason) params.set("reason", reason);
    return C.postJson(
      "/api/cases/" + caseId + "/triage/group/decision?" + params.toString()
    );
  }

  // ── funnel UI ─────────────────────────────────────────────────────────
  function renderFunnel() {
    if (!funnel) return;
    const total = Number(funnel.total || 0);
    const resolved = Number(funnel.resolved || 0);
    const auto = Number(funnel.auto_passable || 0);
    const residual = Number(funnel.residual || 0);
    const flagged = Number(funnel.flagged_pending || 0);

    if (els.funnelTotal) els.funnelTotal.textContent = String(total);
    if (els.funnelAuto) els.funnelAuto.textContent = String(auto);
    if (els.funnelResidual) els.funnelResidual.textContent = String(residual);
    if (els.funnelThrLabel) els.funnelThrLabel.textContent = String(threshold);
    if (els.thrVal) els.thrVal.textContent = String(threshold);
    if (els.thrSlider && Number(els.thrSlider.value) !== threshold) {
      els.thrSlider.value = String(threshold);
    }
    document.querySelectorAll(".thr").forEach((btn) => {
      btn.classList.toggle("on", Number(btn.dataset.thr) === threshold);
    });

    const prog =
      resolved +
      " of " +
      total +
      " resolved · " +
      residual +
      " residual left";
    if (els.funnelProgress) els.funnelProgress.textContent = prog;
    if (els.progressLabel) els.progressLabel.textContent = prog;
    if (els.progressBar) {
      els.progressBar.style.width =
        Math.min(100, Math.round((resolved / Math.max(total, 1)) * 100)) + "%";
    }
    if (els.pendingLabel) {
      els.pendingLabel.textContent = residual + " residual";
    }
    if (els.btnAcceptHighN) els.btnAcceptHighN.textContent = String(auto);
    if (els.btnAcceptHigh) {
      els.btnAcceptHigh.disabled = bulkBusy || auto === 0;
      els.btnAcceptHigh.title =
        auto === 0
          ? "No high-confidence pending at threshold " + threshold
          : "Accept " + auto + " suggestions with conf ≥ " + threshold + " (excludes flagged)";
    }
    if (els.flagExcl) els.flagExcl.classList.toggle("on", flagged > 0);
    if (els.flagExclN) els.flagExclN.textContent = String(flagged);

    if (els.bandHigh) els.bandHigh.textContent = String(funnel.high_pending != null ? funnel.high_pending : "—");
    if (els.bandReview) els.bandReview.textContent = String(funnel.review_pending != null ? funnel.review_pending : "—");
    if (els.bandFlagged) els.bandFlagged.textContent = String(flagged);

    if (els.scopeLabel) {
      els.scopeLabel.textContent = scope === "doc" ? "this document" : "case-wide";
    }
    if (els.residualLabel) {
      const nGroups = residualGroups.length;
      els.residualLabel.textContent =
        "Residual queue · " + nGroups + " group" + (nGroups === 1 ? "" : "s");
    }

    // Math check: pending should ≈ auto + residual
    const pending = Number(funnel.pending || 0);
    if (pending !== auto + residual && els.funnelProgress) {
      // soft note only in console for verify
      console.debug(
        "[triage] pending=" + pending + " auto=" + auto + " residual=" + residual +
          " (delta " + (pending - auto - residual) + ")"
      );
    }
  }

  // ── residual groups render ────────────────────────────────────────────
  function renderQueue() {
    if (!els.qList) return;

    if (!residualGroups.length) {
      const residual = funnel ? Number(funnel.residual || 0) : 0;
      const auto = funnel ? Number(funnel.auto_passable || 0) : 0;
      if (residual === 0 && auto === 0 && funnel && Number(funnel.pending || 0) === 0) {
        els.qList.innerHTML =
          '<div class="empty-q done"><b>Case clear.</b> All suggestions decided. Ready for export check.</div>';
      } else if (residual === 0 && auto > 0) {
        els.qList.innerHTML =
          '<div class="empty-q done"><b>No residual groups.</b> ' +
          auto +
          ' high-confidence still auto-passable — hit <kbd>H</kbd> or the button above.</div>';
      } else {
        els.qList.innerHTML =
          '<div class="empty-q">No residual groups in this scope/band filter. Toggle scope or bands.</div>';
      }
      return;
    }

    const html = [];
    residualGroups.forEach((g, gi) => {
      const excl = exceptionsFor(g.group_key);
      const active = activeIds(g);
      const isCur = gi === groupCursor;
      // Keep every residual group expanded so j/k/a and click targets stay
      // visible in the queue (collapsed bodies made off-cursor instances unclickable).
      const isOpen = true;
      const fr = g.has_flagged || g.group_band === "flagged";
      const nShow = active.length;
      const exclN = excl.size;

      html.push(
        '<div class="rg' +
          (fr ? " flagged" : "") +
          (isCur ? " current" : "") +
          (isOpen ? " open" : "") +
          '" data-group-key="' +
          escapeHtml(g.group_key) +
          '" data-gi="' +
          gi +
          '">' +
          '<div class="rg-head" data-gi="' +
          gi +
          '">' +
          '<div class="rg-top"><b>' +
          escapeHtml(g.group_label) +
          '</b><span class="rg-count">' +
          nShow +
          (exclN ? " (−" + exclN + ")" : "") +
          "</span></div>" +
          '<div class="rg-meta">' +
          (g.kind ? '<span class="ek">' + escapeHtml(g.kind) + " · </span>" : "") +
          g.doc_count +
          " doc" +
          (g.doc_count === 1 ? "" : "s") +
          " · " +
          g.page_count +
          " page" +
          (g.page_count === 1 ? "" : "s") +
          " · conf " +
          g.min_conf +
          (g.min_conf !== g.max_conf ? "–" + g.max_conf : "") +
          "</div>" +
          (g.sample_reason
            ? '<div class="rg-why">' + escapeHtml(g.sample_reason) + "</div>"
            : "") +
          '<div class="rg-actions">' +
          '<button type="button" class="btn accept-g" data-group-accept="' +
          escapeHtml(g.group_key) +
          '">Accept group ×' +
          nShow +
          "</button>" +
          '<button type="button" class="btn reject-g" data-group-reject="' +
          escapeHtml(g.group_key) +
          '">Reject group ×' +
          nShow +
          "</button>" +
          "</div></div>" +
          '<div class="rg-body">' +
          (exclN
            ? '<div class="rg-excl">' +
              exclN +
              " instance" +
              (exclN === 1 ? "" : "s") +
              " excluded from group action (click to re-include)</div>"
            : '<div class="rg-excl">Click instance to open page · <kbd>x</kbd> exclude from group action</div>')
      );

      const insts = g.instances.filter((i) => bandsOn[i.band] !== false);
      insts.forEach((inst, ii) => {
        const isEx = excl.has(inst.id);
        const isInstCur = isCur && ii === instCursor;
        const frI = inst.band === "flagged";
        // Residual instances are pending by definition; status may flip
        // optimistically (accepted/rejected) before the row is dropped.
        const st = inst.status || "pending";
        const swClass =
          st === "accepted" || st === "rejected"
            ? st
            : frI
              ? "flagged"
              : "pending";
        html.push(
          '<div class="sugg' +
            (isInstCur ? " current" : "") +
            (isEx ? " excluded" : "") +
            (frI ? " fr" : "") +
            '" data-id="' +
            inst.id +
            '" data-status="' +
            escapeHtml(st) +
            '" data-group-key="' +
            escapeHtml(g.group_key) +
            '" data-ii="' +
            ii +
            '" data-page="' +
            inst.page_no +
            '" data-doc="' +
            inst.document_id +
            '" data-band="' +
            escapeHtml(inst.band) +
            '" data-conf="' +
            inst.confidence +
            '" data-text="' +
            escapeHtml(inst.text) +
            '" role="button" tabindex="-1">' +
            '<span class="sw ' +
            swClass +
            '"></span>' +
            '<div class="st"><div class="val">' +
            escapeHtml(inst.text) +
            '</div><div class="ctx">' +
            highlightContext(inst.context, inst.text) +
            (inst.filename && inst.document_id !== docId
              ? ' <span class="ek">· ' + escapeHtml(inst.filename) + "</span>"
              : "") +
            "</div></div>" +
            '<div class="sm"><div class="conf ' +
            confClass(inst.band) +
            '">' +
            inst.confidence +
            '</div><div class="pgr">p.' +
            inst.page_no +
            (inst.line_no
              ? ' · <a class="line-addr" href="#L' +
                inst.line_no +
                '" data-line="' +
                inst.line_no +
                '" data-page="' +
                inst.page_no +
                '">L' +
                inst.line_no +
                "</a>"
              : "") +
            "</div></div></div>"
        );
      });
      html.push("</div></div>");
    });
    els.qList.innerHTML = html.join("");
    wireGroupClicks();
  }

  function wireGroupClicks() {
    if (!els.qList) return;
    els.qList.querySelectorAll(".rg-head").forEach((head) => {
      head.addEventListener("click", (e) => {
        if (e.target.closest("button")) return;
        const gi = Number(head.dataset.gi);
        if (!Number.isFinite(gi)) return;
        groupCursor = gi;
        instCursor = 0;
        renderQueue();
        focusCurrentInstance({ navigate: false });
      });
    });
    els.qList.querySelectorAll("[data-group-accept]").forEach((btn) => {
      btn.addEventListener("click", (e) => {
        e.stopPropagation();
        void decideGroup(btn.getAttribute("data-group-accept"), "accepted");
      });
    });
    els.qList.querySelectorAll("[data-group-reject]").forEach((btn) => {
      btn.addEventListener("click", (e) => {
        e.stopPropagation();
        void decideGroup(btn.getAttribute("data-group-reject"), "rejected");
      });
    });
    els.qList.querySelectorAll(".sugg[data-id]").forEach((node) => {
      node.addEventListener("click", (e) => {
        const id = node.dataset.id;
        const gi = residualGroups.findIndex(
          (g) => g.group_key === node.dataset.groupKey
        );
        if (gi >= 0) {
          groupCursor = gi;
          instCursor = Number(node.dataset.ii) || 0;
        }
        if (e.metaKey || e.ctrlKey || e.shiftKey) {
          e.preventDefault();
          toggleException(id, node.dataset.groupKey);
          return;
        }
        renderQueue();
        focusCurrentInstance({ navigate: true });
      });
    });
  }

  function toggleException(id, groupKey) {
    if (!groupKey) return;
    const set = exceptionsFor(groupKey);
    if (set.has(id)) set.delete(id);
    else set.add(id);
    renderQueue();
  }

  function currentGroup() {
    return residualGroups[groupCursor] || null;
  }

  function currentInstance() {
    const g = currentGroup();
    if (!g) return null;
    const insts = g.instances.filter((i) => bandsOn[i.band] !== false);
    return insts[instCursor] || insts[0] || null;
  }

  function focusCurrentInstance(opts) {
    opts = opts || {};
    const inst = currentInstance();
    if (!inst) return;
    // sync page mark if same doc/page
    if (inst.document_id === docId && inst.page_no === pageNo) {
      const s = findById(inst.id);
      if (s) {
        const mark = setMarkCurrent(s);
        if (opts.scrollPage && mark) scrollMarkIntoView(mark);
      }
      if (inst.line_no) highlightLine(inst.line_no, { scroll: !!opts.scrollPage });
    } else if (opts.navigate && inst.document_id === docId && inst.page_no !== pageNo) {
      window.location.href =
        "/documents/" + docId + "/pages/" + inst.page_no + "#s" + inst.id;
    } else if (opts.navigate && inst.document_id !== docId) {
      window.location.href =
        "/documents/" + inst.document_id + "/pages/" + inst.page_no + "#s" + inst.id;
    }
    if (els.qList) {
      const row = els.qList.querySelector('.sugg[data-id="' + inst.id + '"]');
      if (row) row.scrollIntoView({ block: "nearest", behavior: "smooth" });
      const rg = els.qList.querySelector('.rg[data-gi="' + groupCursor + '"]');
      if (rg) rg.scrollIntoView({ block: "nearest", behavior: "smooth" });
    }
  }

  // ── document_lines rail (text stream ↔ PDF snap) ──────────────────────
  function setRailMode(mode) {
    railMode = mode === "lines" ? "lines" : "files";
    const docs = document.getElementById("docs-list");
    const lines = document.getElementById("lines-list");
    const tabF = document.getElementById("rail-tab-files");
    const tabL = document.getElementById("rail-tab-lines");
    const title = document.getElementById("rail-title");
    const meta = document.getElementById("rail-meta");
    if (docs) docs.classList.toggle("hidden", railMode === "lines");
    if (lines) lines.classList.toggle("on", railMode === "lines");
    if (tabF) {
      tabF.classList.toggle("on", railMode === "files");
      tabF.setAttribute("aria-selected", railMode === "files" ? "true" : "false");
    }
    if (tabL) {
      tabL.classList.toggle("on", railMode === "lines");
      tabL.setAttribute("aria-selected", railMode === "lines" ? "true" : "false");
    }
    if (title) title.textContent = railMode === "lines" ? "Lines" : "Documents";
    if (meta) {
      meta.textContent =
        railMode === "lines"
          ? "p." + pageNo + " · " + pageLines.length
          : document.querySelectorAll("#docs-list .doc-item").length + " in case";
    }
  }

  async function loadPageLines() {
    try {
      const res = await fetch(
        "/api/documents/" + docId + "/lines?page=" + pageNo,
        { headers: { Accept: "application/json" } }
      );
      if (!res.ok) {
        pageLines = [];
        return;
      }
      pageLines = extractRows(await res.json()).map((r) => ({
        line_no: Number(r.line_no),
        page_no: Number(r.page_no != null ? r.page_no : pageNo),
        text: r.text || r.line_text || "",
        x0: Number(r.x0),
        y0: Number(r.y0),
        x1: Number(r.x1),
        y1: Number(r.y1),
        hit_count: Number(r.hit_count || 0),
        pending_count: Number(r.pending_count || 0),
      }));
    } catch (_) {
      pageLines = [];
    }
    renderLines();
  }

  function renderLines() {
    const root = document.getElementById("lines-list");
    if (!root) return;
    if (!pageLines.length) {
      root.innerHTML =
        '<div class="empty-q" style="padding:16px 12px;font-size:12px">No lines on this page.</div>';
      return;
    }
    root.innerHTML = pageLines
      .map(function (ln) {
        const has = ln.hit_count > 0;
        const on = currentLineNo === ln.line_no ? " on" : "";
        const hit = has ? " has-hit" : "";
        const tick =
          ln.pending_count > 0
            ? '<span class="line-tick">' + ln.pending_count + "</span>"
            : has
              ? '<span class="line-tick" style="color:var(--ink3)">·</span>'
              : '<span class="line-tick"></span>';
        return (
          '<div class="line-row' +
          hit +
          on +
          '" role="listitem" data-line="' +
          ln.line_no +
          '" title="L' +
          ln.line_no +
          '">' +
          '<span class="line-no">' +
          ln.line_no +
          "</span>" +
          '<span class="line-txt">' +
          escapeHtml(ln.text) +
          "</span>" +
          tick +
          "</div>"
        );
      })
      .join("");
    root.querySelectorAll(".line-row").forEach(function (el) {
      el.addEventListener("click", function () {
        const n = Number(el.dataset.line);
        highlightLine(n, { scroll: true, flash: true, openRail: true });
        // Prefer focusing a pending suggestion on this line when present
        const hit = suggestions.find(
          (s) => s.page_no === pageNo && s.line_no === n && s.status === "pending"
        ) || suggestions.find((s) => s.page_no === pageNo && s.line_no === n);
        if (hit) {
          for (let gi = 0; gi < residualGroups.length; gi++) {
            const ii = residualGroups[gi].instances.findIndex((i) => i.id === hit.id);
            if (ii >= 0) {
              groupCursor = gi;
              instCursor = ii;
              renderQueue();
              focusCurrentInstance({ scrollPage: true });
              return;
            }
          }
          setMarkCurrent(hit);
        }
      });
    });
    if (railMode === "lines") setRailMode("lines");
  }

  function findLine(n) {
    return pageLines.find((l) => l.line_no === Number(n)) || null;
  }

  function highlightLine(lineNo, opts) {
    opts = opts || {};
    const ln = findLine(lineNo);
    if (!ln || !els.page) return;
    currentLineNo = ln.line_no;
    let hl = document.getElementById("line-hl");
    if (!hl) {
      hl = document.createElement("div");
      hl.id = "line-hl";
      hl.className = "line-hl";
      hl.setAttribute("aria-hidden", "true");
      els.page.appendChild(hl);
    }
    const top = ln.y0 * scale;
    const height = Math.max(10, (ln.y1 - ln.y0) * scale + 4);
    hl.style.top = Math.max(0, top - 2) + "px";
    hl.style.height = height + "px";
    hl.style.opacity = "1";
    hl.classList.remove("flash");
    if (opts.flash) {
      void hl.offsetWidth;
      hl.classList.add("flash");
    }
    if (opts.scroll && els.stage) {
      const stageRect = els.stage.getBoundingClientRect();
      const pageRect = els.page.getBoundingClientRect();
      const mid =
        els.stage.scrollTop +
        (pageRect.top - stageRect.top) +
        top -
        stageRect.height / 2 +
        height / 2;
      els.stage.scrollTo({ top: Math.max(0, mid), behavior: "smooth" });
    }
    const root = document.getElementById("lines-list");
    if (root) {
      root.querySelectorAll(".line-row").forEach(function (el) {
        el.classList.toggle("on", Number(el.dataset.line) === ln.line_no);
      });
      const row = root.querySelector('.line-row[data-line="' + ln.line_no + '"]');
      if (row && (opts.openRail || railMode === "lines")) {
        if (opts.openRail) setRailMode("lines");
        row.scrollIntoView({ block: "nearest", behavior: "smooth" });
      }
    }
    if (opts.history !== false && window.history && window.history.replaceState) {
      const base = window.location.pathname + window.location.search;
      window.history.replaceState(null, "", base + "#L" + ln.line_no);
    }
  }

  function wireRailTabs() {
    const tabF = document.getElementById("rail-tab-files");
    const tabL = document.getElementById("rail-tab-lines");
    if (tabF) tabF.addEventListener("click", function () { setRailMode("files"); });
    if (tabL) {
      tabL.addEventListener("click", function () {
        setRailMode("lines");
        if (!pageLines.length) void loadPageLines();
      });
    }
    if (els.qList) {
      els.qList.addEventListener("click", function (e) {
        const a = e.target.closest("a.line-addr");
        if (!a) return;
        e.preventDefault();
        e.stopPropagation();
        const n = Number(a.dataset.line);
        const p = Number(a.dataset.page || pageNo);
        if (p !== pageNo) {
          window.location.href = "/documents/" + docId + "/pages/" + p + "#L" + n;
          return;
        }
        highlightLine(n, { scroll: true, flash: true, openRail: true });
      });
    }
  }

  // ── marks (page canvas) ───────────────────────────────────────────────
  function linkMarksToSuggestions() {
    if (!els.marks) return;
    const pageSuggs = suggestions.filter((s) => s.page_no === pageNo);
    const used = new Set();
    els.marks.querySelectorAll(".mark").forEach((el) => {
      const text = el.dataset.text || "";
      const conf = Number(el.dataset.conf);
      let match =
        pageSuggs.find(
          (s) => !used.has(s.id) && s.text === text && Number(s.confidence) === conf
        ) ||
        pageSuggs.find((s) => !used.has(s.id) && s.text === text) ||
        null;
      if (match) {
        used.add(match.id);
        el.dataset.id = String(match.id);
        applyMarkClass(el, match);
      }
    });
  }

  function applyMarkClass(el, s) {
    STATUS_CLASS.forEach((c) => el.classList.remove(c));
    el.classList.add(markVisualStatus(s));
    el.dataset.status = s.status;
    el.classList.toggle("selected", selected.has(s.id));
  }

  function updateMarkFor(s) {
    if (!els.marks || s.page_no !== pageNo) return;
    let el = els.marks.querySelector('.mark[data-id="' + s.id + '"]');
    if (!el && s.left_px != null) {
      el = document.createElement("div");
      el.className = "mark";
      el.dataset.id = String(s.id);
      el.dataset.text = s.text;
      el.dataset.conf = String(s.confidence);
      el.style.left = s.left_px + "px";
      el.style.top = s.top_px + "px";
      el.style.width = (s.width || 8) + "px";
      el.style.height = (s.height || 12) + "px";
      el.title = s.text + " · conf " + s.confidence;
      els.marks.appendChild(el);
    }
    if (!el) return;
    applyMarkClass(el, s);
  }

  function clearMarkCurrent() {
    if (!els.marks) return;
    els.marks.querySelectorAll(".mark.current").forEach((m) => {
      m.classList.remove("current");
      const tag = m.querySelector(".mark-tag");
      if (tag) tag.remove();
    });
  }

  function setMarkCurrent(s) {
    clearMarkCurrent();
    if (!s || s.page_no !== pageNo || !els.marks) return null;
    const el = els.marks.querySelector('.mark[data-id="' + s.id + '"]');
    if (!el) return null;
    el.classList.add("current");
    let tag = el.querySelector(".mark-tag");
    if (!tag) {
      tag = document.createElement("span");
      tag.className = "mark-tag";
      el.appendChild(tag);
    }
    const kind = s.kind || el.dataset.kind || "match";
    tag.innerHTML = escapeHtml(kind) + " · <b>" + s.confidence + "</b>";
    return el;
  }

  function scrollMarkIntoView(el) {
    if (!el || !els.stage) return;
    const stageRect = els.stage.getBoundingClientRect();
    const markRect = el.getBoundingClientRect();
    const mid =
      els.stage.scrollTop +
      (markRect.top - stageRect.top) -
      stageRect.height / 2 +
      markRect.height / 2;
    els.stage.scrollTo({ top: Math.max(0, mid), behavior: "smooth" });
  }

  function applyLocalStatus(id, status) {
    const s = findById(id);
    if (!s) return null;
    const prev = s.status;
    s.status = status;
    updateMarkFor(s);
    if (status !== "pending") selected.delete(id);
    return { s, prev };
  }

  // ── toast ─────────────────────────────────────────────────────────────
  function toast(msg, undoFn) {
    if (!els.toastHost) return;
    els.toastHost.innerHTML = "";
    const el = document.createElement("div");
    el.className = "toast";
    const m = document.createElement("span");
    m.className = "t-msg";
    m.textContent = msg;
    el.appendChild(m);
    if (undoFn) {
      const b = document.createElement("button");
      b.type = "button";
      b.className = "t-undo";
      b.textContent = "u Undo";
      b.addEventListener("click", () => {
        el.remove();
        undoFn();
      });
      el.appendChild(b);
    }
    els.toastHost.appendChild(el);
    if (lastToastTimer) clearTimeout(lastToastTimer);
    lastToastTimer = setTimeout(() => {
      if (el.parentNode) el.remove();
    }, 4500);
  }

  // ── triage actions ────────────────────────────────────────────────────
  async function refreshTriage() {
    await Promise.all([fetchFunnel(), fetchGroups()]);
    renderFunnel();
    renderQueue();
  }

  async function acceptAllHigh() {
    if (bulkBusy) return;
    const n = funnel ? Number(funnel.auto_passable || 0) : 0;
    if (n === 0) {
      toast("No high-confidence pending at ≥" + threshold);
      return;
    }
    bulkBusy = true;
    if (els.btnAcceptHigh) els.btnAcceptHigh.disabled = true;

    // optimistic: mark local doc suggestions accepted if auto-eligible
    const localIds = suggestions.filter(isAutoEligible).map((s) => s.id);
    localIds.forEach((id) => applyLocalStatus(id, "accepted"));
    undoStack.push({
      kind: "accept-high",
      threshold,
      count: n,
      localIds,
    });

    toast(
      "Accepted " + n + " high-confidence ≥" + threshold,
      () => void undoLast(true)
    );

    const res = await postAcceptHigh();
    bulkBusy = false;

    if (!res || res.ok === false) {
      toast("High-conf accept failed — recheck");
      localIds.forEach((id) => applyLocalStatus(id, "pending"));
    }

    // re-fetch live state so funnel math is server truth
    await fetchLiveSuggestions();
    linkMarksToSuggestions();
    suggestions.forEach(updateMarkFor);
    await refreshTriage();
  }

  async function decideGroup(groupKey, status) {
    if (bulkBusy || !groupKey) return;
    const g = residualGroups.find((x) => x.group_key === groupKey);
    if (!g) return;
    const excl = Array.from(exceptionsFor(groupKey));
    const ids = activeIds(g);
    if (!ids.length) {
      toast("Group empty — all instances excluded");
      return;
    }
    bulkBusy = true;

    // optimistic local
    ids.forEach((id) => applyLocalStatus(id, status));
    undoStack.push({
      kind: "group",
      group_key: groupKey,
      status,
      ids: ids.slice(),
      exclude: excl.slice(),
    });

    const verb = status === "accepted" ? "Accepted" : "Rejected";
    toast(
      verb + " group ×" + ids.length + " — " + shortText(g.group_label),
      () => void undoLast(true)
    );

    // remove group from UI immediately
    residualGroups = residualGroups.filter((x) => x.group_key !== groupKey);
    if (groupCursor >= residualGroups.length) {
      groupCursor = Math.max(0, residualGroups.length - 1);
    }
    groupExceptions.delete(groupKey);
    renderQueue();

    const reason =
      status === "rejected" && g.sample_reason
        ? g.sample_reason
        : "triage group " + status;
    const res = await postGroupDecision(groupKey, status, excl, reason);
    bulkBusy = false;

    if (!res || res.ok === false) {
      toast("Group decision failed — recheck");
    }

    await fetchLiveSuggestions();
    linkMarksToSuggestions();
    suggestions.forEach(updateMarkFor);
    await refreshTriage();
  }

  async function decideInstance(status) {
    const inst = currentInstance();
    if (!inst) return;
    const id = inst.id;
    const s = findById(id);
    const prev = s ? s.status : inst.status || "pending";
    // Optimistic local + residual row status so data-status flips immediately.
    inst.status = status;
    applyLocalStatus(id, status);
    undoStack.push({ kind: "one", id, prevStatus: prev, nextStatus: status });

    const label =
      status === "accepted"
        ? 'Accepted — "' + shortText(inst.text) + '"'
        : status === "rejected"
          ? 'Rejected — "' + shortText(inst.text) + '"'
          : 'Restored — "' + shortText(inst.text) + '"';
    toast(label, status === "pending" ? null : () => void undoLast(true));

    // Paint status on the current row, then drop it from residual UI.
    const g = currentGroup();
    if (els.qList) {
      const row = els.qList.querySelector('.sugg[data-id="' + id + '"]');
      if (row) {
        row.setAttribute("data-status", status);
        const sw = row.querySelector(".sw");
        if (sw) {
          sw.className =
            "sw " +
            (status === "accepted" || status === "rejected"
              ? status
              : isFlagged({ band: inst.band, confidence: inst.confidence })
                ? "flagged"
                : "pending");
        }
      }
    }
    if (g && status !== "pending") {
      // Brief paint, then remove from residual stream.
      g.instances = g.instances.filter((i) => i.id !== id);
      g.n = g.instances.length;
      if (!g.instances.length) {
        residualGroups = residualGroups.filter((x) => x.group_key !== g.group_key);
        if (groupCursor >= residualGroups.length) {
          groupCursor = Math.max(0, residualGroups.length - 1);
        }
      } else if (instCursor >= g.instances.filter((i) => bandsOn[i.band] !== false).length) {
        instCursor = Math.max(
          0,
          g.instances.filter((i) => bandsOn[i.band] !== false).length - 1
        );
      }
    }
    renderQueue();

    if (inflight.has(id + ":" + status)) return;
    inflight.add(id + ":" + status);
    try {
      await postDecision(id, status);
    } finally {
      inflight.delete(id + ":" + status);
    }
    await fetchFunnel();
    renderFunnel();
  }

  async function undoLast(fromToast) {
    const last = undoStack.pop();
    if (!last) {
      await decideInstance("pending");
      return;
    }
    if (last.kind === "accept-high") {
      // restore local + batch pending for those we know
      (last.localIds || []).forEach((id) => applyLocalStatus(id, "pending"));
      if (last.localIds && last.localIds.length) {
        await postBatch(last.localIds, "pending", "undo high-conf auto-pass");
      }
      toast("Undid high-confidence accept (" + (last.count || 0) + ")");
      await fetchLiveSuggestions();
      await refreshTriage();
      return;
    }
    if (last.kind === "group") {
      (last.ids || []).forEach((id) => applyLocalStatus(id, "pending"));
      await postBatch(last.ids || [], "pending", "undo group decision");
      toast("Restored group ×" + (last.ids || []).length);
      await fetchLiveSuggestions();
      await refreshTriage();
      return;
    }
    if (last.kind === "bulk" && last.items) {
      last.items.forEach((b) => applyLocalStatus(b.id, b.prev));
      await postBatch(
        last.items.map((b) => b.id),
        "pending",
        "undo bulk"
      );
      toast("Restored " + last.items.length);
      await refreshTriage();
      return;
    }
    // single
    applyLocalStatus(last.id, last.prevStatus || "pending");
    try {
      await postDecision(last.id, last.prevStatus || "pending");
    } catch (_) {
      /* keep optimistic */
    }
    if (!fromToast) toast("Restored to pending");
    await fetchLiveSuggestions();
    await refreshTriage();
  }

  // ── multi-select bulk (page/high tools — still available) ─────────────
  function filteredDoc() {
    return suggestions.filter((s) => bandsOn[s.band] !== false);
  }

  function selectByFilter(pred) {
    filteredDoc().forEach((s) => {
      if (pred(s) && isEligible(s)) selected.add(s.id);
    });
    updateBulkBar();
  }

  function clearSelection() {
    selected.clear();
    lastSelIdx = -1;
    updateBulkBar();
  }

  function selectedEligible() {
    return Array.from(selected)
      .map(findById)
      .filter((s) => s && isEligible(s));
  }

  function updateBulkBar() {
    const sel = selectedEligible();
    const n = sel.length;
    if (els.bulkSel) els.bulkSel.classList.toggle("on", n > 0);
    if (els.bulkCount) {
      els.bulkCount.textContent = n === 1 ? "1 selected" : n + " selected";
    }
    if (els.bulkMeta) {
      const pages = new Set(sel.map((s) => s.page_no));
      els.bulkMeta.textContent =
        n > 0 ? "· " + pages.size + " page" + (pages.size === 1 ? "" : "s") : "";
    }
    if (els.btnBulkAccept) {
      els.btnBulkAccept.textContent = "Accept " + n + " — lay the ink";
      els.btnBulkAccept.disabled = bulkBusy || n === 0;
    }
    if (els.btnBulkReject) {
      els.btnBulkReject.disabled = bulkBusy || n === 0;
    }
  }

  async function bulkDecide(status) {
    if (bulkBusy) return;
    const sel = selectedEligible();
    if (!sel.length) return;
    bulkBusy = true;
    updateBulkBar();
    const batch = sel.map((s) => ({ id: s.id, prev: s.status, text: s.text }));
    batch.forEach((b) => applyLocalStatus(b.id, status));
    undoStack.push({ kind: "bulk", items: batch, nextStatus: status });
    selected.clear();
    updateBulkBar();
    const verb = status === "accepted" ? "Accepted" : "Rejected";
    toast(
      verb + " " + batch.length + " suggestion" + (batch.length === 1 ? "" : "s"),
      () => void undoLast(true)
    );
    await postBatch(
      batch.map((b) => b.id),
      status,
      "bulk " + status
    );
    bulkBusy = false;
    await fetchLiveSuggestions();
    await refreshTriage();
    updateBulkBar();
  }

  // ── page jump ─────────────────────────────────────────────────────────
  function jumpToPage(p) {
    p = Math.max(1, Math.min(pageCount, Number(p) || 1));
    if (p === pageNo) return;
    window.location.href = "/documents/" + docId + "/pages/" + p;
  }

  function wirePageJump() {
    const go = () => {
      const inp = document.getElementById("page-jump-input");
      if (inp) jumpToPage(inp.value);
    };
    const btn = document.getElementById("page-jump-btn");
    const inp = document.getElementById("page-jump-input");
    if (btn) btn.addEventListener("click", go);
    if (inp) {
      inp.addEventListener("keydown", (e) => {
        if (e.key === "Enter") {
          e.preventDefault();
          go();
        }
      });
    }
    const mGo = document.getElementById("minimap-go");
    const mInp = document.getElementById("minimap-jump");
    if (mGo) {
      mGo.addEventListener("click", () => {
        if (mInp) jumpToPage(mInp.value);
      });
    }
    if (mInp) {
      mInp.addEventListener("keydown", (e) => {
        if (e.key === "Enter") {
          e.preventDefault();
          jumpToPage(mInp.value);
        }
      });
    }
    const firstPend = document.getElementById("btn-first-pend");
    if (firstPend) {
      firstPend.addEventListener("click", () => {
        const items = document.querySelectorAll("#minimap-list a.mi[data-pending]");
        let target = null;
        items.forEach((a) => {
          if (target) return;
          if (Number(a.dataset.pending) > 0) target = Number(a.dataset.page);
        });
        if (target == null) {
          const pend = suggestions.find((s) => s.status === "pending");
          if (pend) target = pend.page_no;
        }
        if (target != null) jumpToPage(target);
        else toast("No pending suggestions in this document");
      });
    }
    const on = document.querySelector("#minimap-list a.mi.on");
    if (on) on.scrollIntoView({ block: "center" });
  }

  // ── keyboard ──────────────────────────────────────────────────────────
  /** Flat residual stream: every visible instance as (gi, ii). */
  function flatResidualSlots() {
    const slots = [];
    residualGroups.forEach((g, gi) => {
      const insts = g.instances.filter((i) => bandsOn[i.band] !== false);
      insts.forEach((_, ii) => slots.push({ gi, ii }));
    });
    return slots;
  }

  function moveGroup(delta) {
    if (!residualGroups.length) return;
    groupCursor = (groupCursor + delta + residualGroups.length) % residualGroups.length;
    instCursor = 0;
    renderQueue();
    focusCurrentInstance({ navigate: false, scrollPage: true });
  }

  /** Move the .sugg.current cursor through residual instances (wraps). */
  function moveInstance(delta) {
    const slots = flatResidualSlots();
    if (!slots.length) return;
    let idx = slots.findIndex((s) => s.gi === groupCursor && s.ii === instCursor);
    if (idx < 0) idx = 0;
    idx = (idx + delta + slots.length) % slots.length;
    groupCursor = slots[idx].gi;
    instCursor = slots[idx].ii;
    renderQueue();
    focusCurrentInstance({ navigate: false, scrollPage: true });
  }

  function setThreshold(t) {
    t = Math.max(60, Math.min(99, Number(t) || THR_DEFAULT));
    if (t === threshold) return;
    threshold = t;
    renderFunnel(); // thr labels immediately
    if (thrDebounce) clearTimeout(thrDebounce);
    thrDebounce = setTimeout(() => {
      void refreshTriage();
    }, 120);
  }

  function onKey(e) {
    if (e.metaKey || e.ctrlKey || e.altKey) return;
    const t = e.target;
    if (C.isEditableTarget(t)) {
      if (e.key === "Escape") t.blur();
      return;
    }

    // Shift+H — accept all high-confidence
    if (e.shiftKey && (e.key === "H" || e.key === "h")) {
      e.preventDefault();
      void acceptAllHigh();
      return;
    }
    // Shift+A / Shift+R — group accept/reject (or multi-select if active)
    if (e.shiftKey && (e.key === "A" || e.key === "a")) {
      e.preventDefault();
      if (selected.size) void bulkDecide("accepted");
      else {
        const g = currentGroup();
        if (g) void decideGroup(g.group_key, "accepted");
      }
      return;
    }
    if (e.shiftKey && (e.key === "R" || e.key === "r")) {
      e.preventDefault();
      if (selected.size) void bulkDecide("rejected");
      else {
        const g = currentGroup();
        if (g) void decideGroup(g.group_key, "rejected");
      }
      return;
    }

    if (e.key === "[" || e.key === "]") {
      e.preventDefault();
      setThreshold(threshold + (e.key === "]" ? 1 : -1));
      return;
    }

    const key = e.key.length === 1 ? e.key.toLowerCase() : e.key;
    switch (key) {
      case "j":
        e.preventDefault();
        // j/k = residual queue cursor (instance stream). Shift+j/k = group jump.
        if (e.shiftKey) moveGroup(1);
        else moveInstance(1);
        break;
      case "k":
        e.preventDefault();
        if (e.shiftKey) moveGroup(-1);
        else moveInstance(-1);
        break;
      case "h":
        // plain h also accepts high (shift already handled)
        e.preventDefault();
        void acceptAllHigh();
        break;
      case "a":
        e.preventDefault();
        void decideInstance("accepted");
        break;
      case "r":
        e.preventDefault();
        void decideInstance("rejected");
        break;
      case "x":
        e.preventDefault();
        {
          const inst = currentInstance();
          const g = currentGroup();
          if (inst && g) toggleException(inst.id, g.group_key);
        }
        break;
      case "o":
        e.preventDefault();
        focusCurrentInstance({ navigate: true, scrollPage: true });
        break;
      case "u":
        e.preventDefault();
        void undoLast(false);
        break;
      case "e":
        e.preventDefault();
        {
          const g = currentGroup();
          if (g && g.entity_id != null) {
            window.location.href =
              "/ui/bulk?entity=" + g.entity_id + "&case=" + caseId;
          } else {
            window.location.href = "/ui/bulk?case=" + caseId;
          }
        }
        break;
      case "n":
        e.preventDefault();
        window.location.href = "/ui/add-missed?doc=" + docId;
        break;
      case "g":
        e.preventDefault();
        {
          const inp = document.getElementById("page-jump-input");
          if (inp) {
            inp.focus();
            inp.select();
          }
        }
        break;
      case "Escape":
        e.preventDefault();
        clearSelection();
        break;
      default:
        break;
    }
  }

  // ── wire UI controls ──────────────────────────────────────────────────
  function wireFunnelControls() {
    if (els.btnAcceptHigh) {
      els.btnAcceptHigh.addEventListener("click", () => void acceptAllHigh());
    }
    document.querySelectorAll(".thr").forEach((btn) => {
      btn.addEventListener("click", () => setThreshold(Number(btn.dataset.thr)));
    });
    if (els.thrSlider) {
      els.thrSlider.addEventListener("input", () => {
        setThreshold(Number(els.thrSlider.value));
      });
    }
    const scopeCase = document.getElementById("btn-scope-case");
    const scopeDoc = document.getElementById("btn-scope-doc");
    if (scopeCase) {
      scopeCase.addEventListener("click", () => {
        scope = "case";
        scopeCase.classList.add("on");
        if (scopeDoc) scopeDoc.classList.remove("on");
        void refreshTriage();
      });
    }
    if (scopeDoc) {
      scopeDoc.addEventListener("click", () => {
        scope = "doc";
        scopeDoc.classList.add("on");
        if (scopeCase) scopeCase.classList.remove("on");
        void refreshTriage();
      });
    }
    const pendBtn = document.getElementById("btn-pending-only");
    if (pendBtn) {
      pendBtn.addEventListener("click", () => {
        pendingOnly = !pendingOnly;
        pendBtn.classList.toggle("on", pendingOnly);
        pendBtn.setAttribute("aria-pressed", pendingOnly ? "true" : "false");
        // residual API is already pending-only; toggle is informational + band default
        void refreshTriage();
      });
    }
  }

  function wireBands() {
    if (!els.bandFilters) return;
    els.bandFilters.querySelectorAll(".band").forEach((btn) => {
      btn.addEventListener("click", () => {
        const b = btn.dataset.band;
        if (!b) return;
        bandsOn[b] = !bandsOn[b];
        btn.classList.toggle("on", bandsOn[b]);
        btn.setAttribute("aria-pressed", bandsOn[b] ? "true" : "false");
        void fetchGroups().then(() => {
          renderQueue();
          renderFunnel();
        });
      });
    });
  }

  function wireSelectTools() {
    const pageBtn = document.getElementById("btn-sel-page");
    const highBtn = document.getElementById("btn-sel-high");
    const bandBtn = document.getElementById("btn-sel-band");
    const noneBtn = document.getElementById("btn-sel-none");
    if (pageBtn) {
      pageBtn.addEventListener("click", () => {
        selectByFilter((s) => s.page_no === pageNo);
      });
    }
    if (highBtn) {
      highBtn.addEventListener("click", () => {
        selectByFilter((s) => s.band === "high");
      });
    }
    if (bandBtn) {
      bandBtn.addEventListener("click", () => selectByFilter(() => true));
    }
    if (noneBtn) noneBtn.addEventListener("click", clearSelection);
    if (els.btnBulkAccept) {
      els.btnBulkAccept.addEventListener("click", () => void bulkDecide("accepted"));
    }
    if (els.btnBulkReject) {
      els.btnBulkReject.addEventListener("click", () => void bulkDecide("rejected"));
    }
  }

  function wireMarks() {
    if (!els.marks) return;
    els.marks.addEventListener("click", (e) => {
      const el = e.target.closest(".mark");
      if (!el || !el.dataset.id) return;
      const id = el.dataset.id;
      // find in residual groups
      for (let gi = 0; gi < residualGroups.length; gi++) {
        const g = residualGroups[gi];
        const ii = g.instances.findIndex((i) => i.id === id);
        if (ii >= 0) {
          groupCursor = gi;
          instCursor = ii;
          renderQueue();
          focusCurrentInstance({ scrollPage: true });
          return;
        }
      }
      // not residual — maybe auto-pass high; still focus mark
      const s = findById(id);
      if (s) setMarkCurrent(s);
    });
  }

  function focusFromHash() {
    const hash = window.location.hash || "";
    // Line snap: #L17
    const lm = /^#L(\d+)/i.exec(hash);
    if (lm) {
      const n = Number(lm[1]);
      highlightLine(n, { scroll: true, flash: true, openRail: true, history: false });
      return;
    }
    // Opaque string suggestion ids (uuid), not legacy integer ids.
    const m = /^#s(.+)/.exec(hash);
    if (!m) return;
    const id = m[1];
    for (let gi = 0; gi < residualGroups.length; gi++) {
      const g = residualGroups[gi];
      const ii = g.instances.findIndex((i) => i.id === id);
      if (ii >= 0) {
        groupCursor = gi;
        instCursor = ii;
        return;
      }
    }
  }

  async function init() {
    suggestions = readDomSuggestions();

    linkMarksToSuggestions();
    suggestions.forEach(updateMarkFor);

    wireFunnelControls();
    wireBands();
    wireMarks();
    wirePageJump();
    wireSelectTools();
    wireRailTabs();
    document.addEventListener("keydown", onKey);

    // hydrate from APIs
    await fetchLiveSuggestions();
    linkMarksToSuggestions();
    suggestions.forEach(updateMarkFor);

    await Promise.all([refreshTriage(), loadPageLines()]);
    focusFromHash();
    renderQueue();
    focusCurrentInstance({ scrollPage: true });

    window.__review = {
      funnel: () => funnel,
      residualGroups: () => residualGroups,
      threshold: () => threshold,
      setThreshold,
      acceptHigh: () => acceptAllHigh(),
      decideGroup,
      selected: () => Array.from(selected),
      suggestions: () => suggestions,
      pageLines: () => pageLines,
      highlightLine: (n) => highlightLine(n, { scroll: true, flash: true, openRail: true }),
      refresh: () => refreshTriage(),
    };
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", init);
  } else {
    init();
  }
})();
