/* Closure — reject false-positive flow
 * Route: GET /ui/reject?doc=<id>&sug=<id>
 * Contract APIs:
 *   GET  /api/documents/:id/suggestions
 *   GET  /api/cases/:id/suggestions
 *   POST /api/suggestions/:id/decision?status=&reason=&actor=
 *   POST /api/entities/:id/decision?status=&actor=   (fan-out; excludes flagged)
 */
(function () {
  "use strict";

  var ACTOR = "A. Subbarao";
  var DISPLAY_W = 700;
  var TOAST_MS = 8000;

  var params = new URLSearchParams(window.location.search);
  var docId = params.get("doc") || "1";
  var sugParam = params.get("sug");
  var sugId = sugParam || null;

  var state = {
    doc: {
      id: docId,
      filename: null,
      case_id: null,
      case_no: null,
      width_pt: 612,
      height_pt: 792,
      page_count: 1
    },
    docSuggestions: [],
    caseSuggestions: [],
    currentId: null,
    pageNo: 1,
    busy: false,
    undo: null,
    toastTimer: null,
    lastResponses: []
  };

  var el = {
    err: document.getElementById("err-banner"),
    crumbCase: document.getElementById("crumb-case"),
    crumbDoc: document.getElementById("crumb-doc"),
    progressLabel: document.getElementById("progress-label"),
    progressBar: document.getElementById("progress-bar"),
    btnAudit: document.getElementById("btn-audit"),
    btnExport: document.getElementById("btn-export"),
    pgPrev: document.getElementById("pg-prev"),
    pgNext: document.getElementById("pg-next"),
    pgLabel: document.getElementById("pg-label"),
    pgMarks: document.getElementById("pg-marks"),
    pdfPage: document.getElementById("pdf-page"),
    pageLoading: document.getElementById("page-loading"),
    pdfBg: document.getElementById("pdf-bg"),
    markLayer: document.getElementById("mark-layer"),
    whyCard: document.getElementById("why-card"),
    whyBody: document.getElementById("why-body"),
    btnReject: document.getElementById("btn-reject"),
    btnKeep: document.getElementById("btn-keep"),
    hintRejectAll: document.getElementById("hint-reject-all"),
    pendCount: document.getElementById("pend-count"),
    matchPanel: document.getElementById("match-panel"),
    matchBody: document.getElementById("match-body"),
    matchList: document.getElementById("match-list"),
    btnRejectAll: document.getElementById("btn-reject-all"),
    auditPreview: document.getElementById("audit-preview"),
    auditBody: document.getElementById("audit-body"),
    qList: document.getElementById("q-list"),
    toast: document.getElementById("undo-toast"),
    toastTitle: document.getElementById("toast-title"),
    toastDetail: document.getElementById("toast-detail"),
    btnUndo: document.getElementById("btn-undo")
  };

  function showErr(msg) {
    el.err.textContent = msg;
    el.err.classList.add("show");
  }
  function clearErr() {
    el.err.classList.remove("show");
    el.err.textContent = "";
  }

  function esc(s) {
    return String(s == null ? "" : s)
      .replace(/&/g, "&amp;")
      .replace(/</g, "&lt;")
      .replace(/>/g, "&gt;")
      .replace(/"/g, "&quot;");
  }

  function bandOf(s) {
    if (s.band) return s.band;
    var c = Number(s.confidence) || 0;
    if (c >= 90) return "high";
    if (c >= 60) return "review";
    return "flagged";
  }

  function statusOf(s) {
    return s.status || "pending";
  }

  function isPending(s) {
    return statusOf(s) === "pending";
  }

  function markClass(s, isCurrent) {
    var st = statusOf(s);
    var b = bandOf(s);
    if (st === "accepted") return "accepted";
    if (st === "rejected") return "rejected";
    if (isCurrent && (b === "flagged" || s.flag_tag === "false_positive")) return "focus-flag";
    if (b === "flagged" || s.flag_tag === "false_positive") return "flagged";
    return "pending";
  }

  function swClass(s) {
    var st = statusOf(s);
    if (st === "accepted") return "accepted";
    if (st === "rejected") return "rejected";
    if (bandOf(s) === "flagged" || s.flag_tag === "false_positive") return "flagged";
    return "pending";
  }

  function confClass(s) {
    var b = bandOf(s);
    if (b === "high") return "h";
    if (b === "review") return "m";
    return "l";
  }

  function scale() {
    return DISPLAY_W / (Number(state.doc.width_pt) || 612);
  }

  function boxPx(s) {
    var sc = scale();
    var x0 = Number(s.x0) || 0;
    var y0 = Number(s.y0) || 0;
    var x1 = Number(s.x1) || x0;
    var y1 = Number(s.y1) || y0;
    return {
      left: x0 * sc,
      top: y0 * sc,
      width: Math.max(2, (x1 - x0) * sc),
      height: Math.max(2, (y1 - y0) * sc)
    };
  }

  function patternFrom(s) {
    var reason = String(s.reason || "");
    var m = reason.match(/PERSON|SSN|DOB|ADDRESS|PHONE|EMAIL|CITATION|OFFICER|DRIVER|PLATE|ACCOUNT/i);
    if (m) return m[0].toUpperCase();
    var kind = String(s.kind || s.entity_kind || "");
    if (kind) {
      var k = kind.split("·")[0].trim();
      if (k) return k.toUpperCase();
    }
    return "PERSON";
  }

  function auditReasonLabel(s) {
    var kind = String(s.kind || s.entity_text || s.entity_kind || "").toLowerCase();
    var reason = String(s.reason || "").toLowerCase();
    if (kind.indexOf("street") >= 0 || reason.indexOf("street") >= 0) return "street name";
    if (kind.indexOf("citation") >= 0 || reason.indexOf("citation") >= 0) return "case citation";
    if (kind.indexOf("officer") >= 0 || reason.indexOf("officer") >= 0) return "officer of record";
    return "not PII";
  }

  function contextPhrase(s) {
    var label = auditReasonLabel(s);
    if (label === "street name") return "a street address";
    if (label === "case citation") return "a published case citation";
    if (label === "officer of record") return "an officer of record";
    return "a non-subject mention";
  }

  function normalizeList(payload) {
    if (!payload) return [];
    if (Array.isArray(payload)) {
      // quackapi may return [{suggestions: [...]}] or bare rows
      if (payload.length === 1 && payload[0] && Array.isArray(payload[0].suggestions)) {
        return payload[0].suggestions;
      }
      if (payload.length === 1 && payload[0] && Array.isArray(payload[0].rows)) {
        return payload[0].rows;
      }
      return payload;
    }
    if (Array.isArray(payload.suggestions)) return payload.suggestions;
    if (Array.isArray(payload.rows)) return payload.rows;
    if (Array.isArray(payload.data)) return payload.data;
    return [];
  }

  async function fetchJson(url, opts) {
    opts = opts || {};
    // quackapi POST handlers hang if the request has no body/Content-Length
    if ((opts.method || "GET").toUpperCase() === "POST") {
      opts = Object.assign({}, opts);
      if (opts.body == null) opts.body = "{}";
      opts.headers = Object.assign({ "Content-Type": "application/json" }, opts.headers || {});
    }
    var res = await fetch(url, opts);
    var text = await res.text();
    var data = null;
    try {
      data = text ? JSON.parse(text) : null;
    } catch (e) {
      data = { raw: text };
    }
    return { ok: res.ok, status: res.status, data: data, text: text, url: url };
  }

  async function loadDocMetaFromHtml() {
    var res = await fetch("/documents/" + docId);
    if (!res.ok) return;
    var html = await res.text();
    var title = html.match(/Review ·\s*([^<]+?)\.pdf/i);
    if (title) state.doc.filename = title[1].trim();
    var caseLink = html.match(/\/cases\/([^/"'?\s]+)/);
    if (caseLink) state.doc.case_id = caseLink[1];
    var caseNo = html.match(/CASE\s+([0-9-]+)/i);
    if (caseNo) state.doc.case_no = caseNo[1];
    var pageCount = html.match(/PAGE\s+\d+\s*\/\s*(\d+)/i);
    if (pageCount) state.doc.page_count = parseInt(pageCount[1], 10);
    // width/height from coordinate proof line if present
    var dims = html.match(/page\s+([\d.]+)\s*[×x]\s*([\d.]+)\s*pt/i);
    if (dims) {
      state.doc.width_pt = parseFloat(dims[1]);
      state.doc.height_pt = parseFloat(dims[2]);
    }
  }

  async function loadDocSuggestions() {
    var paths = [
      "/api/documents/" + docId + "/suggestions",
      "/api/documents/" + docId + "/suggestions?status=all"
    ];
    var last = null;
    for (var i = 0; i < paths.length; i++) {
      last = await fetchJson(paths[i]);
      if (last.ok) {
        state.docSuggestions = normalizeList(last.data).map(function (r) {
          return Object.assign({}, r, { id: r.id != null ? String(r.id) : r.id });
        });
        return last;
      }
    }
    throw new Error(
      "GET /api/documents/" +
        docId +
        "/suggestions failed (" +
        (last && last.status) +
        "). Backend route required."
    );
  }

  async function loadCaseSuggestions() {
    var caseId = state.doc.case_id;
    if (!caseId) {
      // Probe cases 1..8 for any row belonging to this document
      for (var c = 1; c <= 8; c++) {
        var probe = await fetchJson("/api/cases/" + c + "/suggestions");
        if (!probe.ok) continue;
        var rows = normalizeList(probe.data);
        var hit = rows.some(function (r) {
          return String(r.document_id) === String(docId);
        });
        if (hit) {
          state.doc.case_id = String(c);
          state.caseSuggestions = rows.map(function (r) {
            return Object.assign({}, r, { id: r.id != null ? String(r.id) : r.id });
          });
          return probe;
        }
      }
      state.caseSuggestions = state.docSuggestions.slice();
      return null;
    }
    var res = await fetchJson("/api/cases/" + caseId + "/suggestions");
    if (!res.ok) {
      state.caseSuggestions = state.docSuggestions.slice();
      return res;
    }
    state.caseSuggestions = normalizeList(res.data).map(function (r) {
      return Object.assign({}, r, { id: r.id != null ? String(r.id) : r.id });
    });
    return res;
  }

  function byId(id) {
    if (id == null) return null;
    id = String(id);
    var pool = state.caseSuggestions.length ? state.caseSuggestions : state.docSuggestions;
    for (var i = 0; i < pool.length; i++) if (String(pool[i].id) === id) return pool[i];
    for (var j = 0; j < state.docSuggestions.length; j++) {
      if (String(state.docSuggestions[j].id) === id) return state.docSuggestions[j];
    }
    return null;
  }

  function current() {
    return byId(state.currentId);
  }

  function matchingFor(s) {
    if (!s) return [];
    var text = s.text;
    var pool = state.caseSuggestions.length ? state.caseSuggestions : state.docSuggestions;
    return pool.filter(function (r) {
      return r.text === text;
    });
  }

  function pendingMatching(s) {
    return matchingFor(s).filter(isPending);
  }

  function pickCurrent() {
    if (sugId && byId(sugId)) {
      state.currentId = sugId;
      return;
    }
    // Prefer false_positive / flagged pending on this doc
    var fp = state.docSuggestions.find(function (s) {
      return isPending(s) && (s.flag_tag === "false_positive" || bandOf(s) === "flagged");
    });
    if (fp) {
      state.currentId = String(fp.id);
      return;
    }
    var pend = state.docSuggestions.find(isPending);
    if (pend) {
      state.currentId = String(pend.id);
      return;
    }
    if (state.docSuggestions[0]) state.currentId = String(state.docSuggestions[0].id);
  }

  function setStatusLocal(ids, status) {
    var set = {};
    ids.forEach(function (id) {
      set[String(id)] = true;
    });
    function bump(arr) {
      arr.forEach(function (s) {
        if (set[String(s.id)]) s.status = status;
      });
    }
    bump(state.docSuggestions);
    bump(state.caseSuggestions);
  }

  async function postDecision(id, status, reason) {
    // Contract: POST /api/suggestions/:id/decision?status=&reason=&actor=
    // Also send action= for older handlers that bind $action.
    var q = new URLSearchParams();
    q.set("status", status);
    q.set("action", status);
    q.set("actor", ACTOR);
    if (reason) q.set("reason", reason);
    var url = "/api/suggestions/" + id + "/decision?" + q.toString();
    var res = await fetchJson(url, { method: "POST" });
    if (!res.ok) {
      var q2 = new URLSearchParams();
      q2.set("action", status);
      q2.set("status", status);
      if (reason) q2.set("reason", reason);
      q2.set("actor", ACTOR);
      res = await fetchJson("/suggestions/" + id + "/decision?" + q2.toString(), {
        method: "POST"
      });
    }
    state.lastResponses.push({ kind: "suggestion", id: id, status: status, res: res });
    return res;
  }

  async function postEntityDecision(entityId, status, reason) {
    var q = new URLSearchParams();
    q.set("status", status);
    q.set("action", status);
    q.set("actor", ACTOR);
    if (reason) q.set("reason", reason);
    var url = "/api/entities/" + entityId + "/decision?" + q.toString();
    var res = await fetchJson(url, { method: "POST" });
    state.lastResponses.push({ kind: "entity", id: entityId, status: status, res: res });
    return res;
  }

  function showToast(title, detail, undoPayload) {
    el.toastTitle.textContent = title;
    el.toastDetail.textContent = detail || "";
    state.undo = undoPayload || null;
    el.toast.classList.add("show");
    if (state.toastTimer) clearTimeout(state.toastTimer);
    state.toastTimer = setTimeout(function () {
      el.toast.classList.remove("show");
      // keep undo for keyboard for a bit longer? clear after hide
      // retain undo until next action or explicit expiry
    }, TOAST_MS);
  }

  function hideToast() {
    el.toast.classList.remove("show");
  }

  async function rejectOne() {
    var s = current();
    if (!s || state.busy) return;
    if (!isPending(s)) return;
    state.busy = true;
    setButtonsBusy(true);
    var reason = auditReasonLabel(s);
    try {
      var res = await postDecision(s.id, "rejected", reason);
      if (!res.ok) {
        showErr("Reject failed HTTP " + res.status + ": " + (res.text || "").slice(0, 200));
        return;
      }
      setStatusLocal([s.id], "rejected");
      showToast('Rejected — "' + s.text + '"', "Logged: " + ACTOR + " · reason: " + reason, {
        ids: [s.id],
        prior: "pending",
        text: s.text
      });
      render();
    } finally {
      state.busy = false;
      setButtonsBusy(false);
    }
  }

  async function keepOne() {
    var s = current();
    if (!s || state.busy) return;
    if (!isPending(s)) return;
    state.busy = true;
    setButtonsBusy(true);
    try {
      var res = await postDecision(s.id, "accepted", "keep — true positive");
      if (!res.ok) {
        showErr("Keep failed HTTP " + res.status + ": " + (res.text || "").slice(0, 200));
        return;
      }
      setStatusLocal([s.id], "accepted");
      showToast('Accepted — "' + s.text + '"', "Logged: " + ACTOR, {
        ids: [s.id],
        prior: "pending",
        text: s.text
      });
      render();
    } finally {
      state.busy = false;
      setButtonsBusy(false);
    }
  }

  async function rejectAllMatching() {
    var s = current();
    if (!s || state.busy) return;
    var matches = pendingMatching(s);
    if (!matches.length) return;
    state.busy = true;
    setButtonsBusy(true);
    var reason = auditReasonLabel(s);
    var ids = matches.map(function (m) {
      return String(m.id);
    });
    var responses = [];
    try {
      // Fan-out: loop matching suggestion ids (contract allows this).
      // Optionally poke entity endpoint first for audit/backends that fan out server-side;
      // always apply per-suggestion POSTs so flagged-band + non-entity matches clear too.
      var entityIds = {};
      matches.forEach(function (m) {
        if (m.entity_id != null) entityIds[String(m.entity_id)] = true;
      });
      var entityKeys = Object.keys(entityIds);
      if (entityKeys.length === 1 && entityKeys[0] !== "null" && entityKeys[0] !== "undefined") {
        try {
          responses.push(await postEntityDecision(entityKeys[0], "rejected", reason));
        } catch (e) {
          /* entity route optional */
        }
      }
      for (var j = 0; j < matches.length; j++) {
        var r2 = await postDecision(matches[j].id, "rejected", reason);
        responses.push(r2);
        if (r2.ok) setStatusLocal([matches[j].id], "rejected");
      }
      var okN = responses.filter(function (r) {
        return r.ok;
      }).length;
      if (!okN) {
        showErr(
          "Reject all failed. Last: HTTP " +
            (responses[responses.length - 1] && responses[responses.length - 1].status) +
            " " +
            ((responses[responses.length - 1] && responses[responses.length - 1].text) || "").slice(0, 180)
        );
        return;
      }
      showToast(
        'Rejected — "' + s.text + '"',
        "Logged: " + ACTOR + " · reason: " + reason + " · " + ids.length + " instances cleared",
        { ids: ids, prior: "pending", text: s.text }
      );
      // expose last bulk response for verify tooling
      window.__REJECT_LAST_BULK__ = { ids: ids, responses: responses };
      render();
    } finally {
      state.busy = false;
      setButtonsBusy(false);
    }
  }

  async function undoLast() {
    if (!state.undo || state.busy) return;
    var u = state.undo;
    state.busy = true;
    try {
      for (var i = 0; i < u.ids.length; i++) {
        var res = await postDecision(u.ids[i], "pending", "undo");
        if (res.ok) setStatusLocal([u.ids[i]], "pending");
      }
      showToast('Restored to pending — "' + u.text + '"', "");
      state.undo = null;
      hideToast();
      render();
    } finally {
      state.busy = false;
    }
  }

  function setButtonsBusy(b) {
    el.btnReject.disabled = b;
    el.btnKeep.disabled = b;
    el.btnRejectAll.disabled = b;
  }

  function renderChrome() {
    var d = state.doc;
    var caseLabel = d.case_no ? "CASE " + d.case_no : d.case_id ? "CASE #" + d.case_id : "CASE";
    el.crumbCase.innerHTML = d.case_id
      ? '<a href="/cases/' + d.case_id + '">' + esc(caseLabel) + "</a>"
      : esc(caseLabel);
    el.crumbDoc.textContent = (d.filename || "document_" + d.id) + ".pdf";
    document.title = "Closure — Reject false positive · " + (d.filename || "doc") + ".pdf";

    if (d.case_id) {
      el.btnAudit.href = "/cases/" + d.case_id + "/audit";
      el.btnExport.href = "/cases/" + d.case_id;
    }

    var pool = state.caseSuggestions.length ? state.caseSuggestions : state.docSuggestions;
    // progress scoped to current document
    var docPool = state.docSuggestions;
    var total = docPool.length;
    var done = docPool.filter(function (s) {
      return !isPending(s);
    }).length;
    el.progressLabel.textContent = done + " of " + total;
    el.progressBar.style.width = total ? Math.round((done / total) * 100) + "%" : "0%";

    var pend = docPool.filter(isPending).length;
    el.pendCount.textContent = pend + " pending";

    var s = current();
    var pageNo = s ? Number(s.page_no) || 1 : state.pageNo;
    state.pageNo = pageNo;
    var pageCount = d.page_count || 1;
    el.pgLabel.textContent = "PAGE " + pageNo + " / " + pageCount;
    el.pgPrev.disabled = pageNo <= 1;
    el.pgNext.disabled = pageNo >= pageCount;

    var onPage = docPool.filter(function (x) {
      return Number(x.page_no) === pageNo;
    });
    el.pgMarks.textContent = onPage.length + " mark" + (onPage.length === 1 ? "" : "s") + " on this page";
  }

  function renderPage() {
    var d = state.doc;
    var sc = scale();
    var h = (Number(d.height_pt) || 792) * sc;
    el.pdfPage.style.width = DISPLAY_W + "px";
    el.pdfPage.style.height = h + "px";

    var s = current();
    var pageNo = state.pageNo;
    if (d.filename) {
      var src = "/pages/" + d.filename + "/p" + pageNo + ".png";
      el.pdfBg.hidden = false;
      el.pdfBg.alt = "page " + pageNo;
      if (el.pdfBg.getAttribute("src") !== src) {
        el.pageLoading.hidden = false;
        el.pdfBg.onload = function () {
          el.pageLoading.hidden = true;
        };
        el.pdfBg.onerror = function () {
          el.pageLoading.textContent = "No page PNG at " + src + " — marks still drawn from PDF coordinates.";
          el.pageLoading.hidden = false;
        };
        el.pdfBg.src = src;
      } else {
        el.pageLoading.hidden = true;
      }
    } else {
      el.pdfBg.hidden = true;
      el.pageLoading.textContent = "Document metadata incomplete — drawing marks only.";
      el.pageLoading.hidden = false;
    }

    // marks on this page (doc-scoped)
    var marks = state.docSuggestions.filter(function (x) {
      return Number(x.page_no) === pageNo;
    });
    el.markLayer.innerHTML = "";
    marks.forEach(function (m) {
      var isCur = String(m.id) === String(state.currentId);
      var box = boxPx(m);
      var div = document.createElement("div");
      div.className = "mark " + markClass(m, isCur) + (isCur ? " current" : "");
      div.style.left = box.left + "px";
      div.style.top = box.top + "px";
      div.style.width = box.width + "px";
      div.style.height = box.height + "px";
      div.title = m.text + " · conf " + m.confidence;
      div.dataset.id = m.id;
      div.addEventListener("click", function (ev) {
        ev.stopPropagation();
        state.currentId = String(m.id);
        // update URL without reload
        var u = new URL(window.location.href);
        u.searchParams.set("doc", String(docId));
        u.searchParams.set("sug", String(m.id));
        history.replaceState(null, "", u.toString());
        render();
      });
      el.markLayer.appendChild(div);
    });

    renderWhyCard(s);
  }

  function renderWhyCard(s) {
    if (!s || Number(s.page_no) !== state.pageNo) {
      el.whyCard.hidden = true;
      return;
    }
    // Only show why-card for judgment moments (FP / flagged / review-band pending)
    var show =
      isPending(s) &&
      (s.flag_tag === "false_positive" || bandOf(s) === "flagged" || bandOf(s) === "review");
    if (!show) {
      el.whyCard.hidden = true;
      return;
    }

    var reason = s.reason || "AI lowered confidence on this match.";
    var conf = s.confidence != null ? s.confidence : "—";
    var pattern = patternFrom(s);
    // Prefer data reason; if short, append confidence line from copy pattern
    var body =
      esc(reason) +
      (String(reason).toLowerCase().indexOf("confidence") >= 0
        ? ""
        : " Confidence lowered to <b>" + esc(conf) + "</b>.");
    el.whyBody.innerHTML = body;

    var box = boxPx(s);
    el.whyCard.hidden = false;
    // Anchor to the right of the mark; flip left if overflow
    var cardW = 296;
    var left = box.left + box.width + 12;
    if (left + cardW > DISPLAY_W + 40) {
      left = Math.max(0, box.left - cardW - 12);
    }
    var top = Math.max(0, box.top - 16);
    el.whyCard.style.left = left + "px";
    el.whyCard.style.top = top + "px";
    el.whyCard.style.right = "auto";
  }

  function renderMatchPanel() {
    var s = current();
    if (!s) {
      el.matchPanel.classList.remove("show");
      el.auditPreview.classList.remove("show");
      return;
    }
    var matches = matchingFor(s);
    var pending = matches.filter(isPending);
    var n = matches.length;
    var docs = {};
    matches.forEach(function (m) {
      docs[String(m.document_id)] = true;
    });
    var dCount = Object.keys(docs).length;
    var pattern = patternFrom(s);
    var ctx = contextPhrase(s);
    var reason = auditReasonLabel(s);

    // Copy: "{text}" matched the {PATTERN} pattern {n} times across {d} documents — always as {context}, never as the subject.
    el.matchBody.innerHTML =
      '"' +
      esc(s.text) +
      '" matched the <b>' +
      esc(pattern) +
      "</b> pattern <b>" +
      n +
      " time" +
      (n === 1 ? "" : "s") +
      "</b> across <b>" +
      dCount +
      " document" +
      (dCount === 1 ? "" : "s") +
      "</b> — always as " +
      esc(ctx) +
      ", never as the subject.";

    // Group by document for the mini list
    var byDoc = {};
    matches.forEach(function (m) {
      var key = String(m.document_id);
      if (!byDoc[key]) byDoc[key] = { id: m.document_id, pages: [], filename: m.filename || null };
      byDoc[key].pages.push(Number(m.page_no));
    });
    el.matchList.innerHTML = Object.keys(byDoc)
      .map(function (k) {
        var g = byDoc[k];
        var pages = g.pages
          .filter(function (v, i, a) {
            return a.indexOf(v) === i;
          })
          .sort(function (a, b) {
            return a - b;
          });
        var pageStr = pages
          .slice(0, 4)
          .map(function (p) {
            return "p." + p;
          })
          .join(", ");
        if (pages.length > 4) pageStr += "…";
        var name = g.filename || "document_" + g.id;
        return (
          '<div class="match-row"><span class="match-dot"></span>' +
          esc(name) +
          " <b>· " +
          esc(pageStr) +
          "</b></div>"
        );
      })
      .join("");

    el.btnRejectAll.textContent =
      "Reject all " + pending.length + ' — log as "' + reason + '"';
    el.btnRejectAll.disabled = pending.length === 0 || state.busy;
    el.matchPanel.classList.add("show");

    el.hintRejectAll.textContent = "Reject all " + pending.length;

    // Audit preview
    var now = new Date();
    var hh = String(now.getHours()).padStart(2, "0");
    var mm = String(now.getMinutes()).padStart(2, "0");
    el.auditBody.innerHTML =
      "Rejected by <b>" +
      esc(ACTOR) +
      "</b> · <b>" +
      hh +
      ":" +
      mm +
      "</b> · item <b>\"" +
      esc(s.text) +
      '"</b> p.' +
      esc(s.page_no) +
      " · reason: <b>not PII — " +
      esc(reason) +
      "</b> · prior state: " +
      esc(statusOf(s)) +
      " · confidence " +
      esc(s.confidence);
    el.auditPreview.classList.add("show");
  }

  function highlightCtx(ctx, text) {
    if (!ctx) return "";
    var c = String(ctx);
    var t = String(text || "");
    if (!t) return esc(c);
    var idx = c.indexOf(t);
    if (idx < 0) return esc(c);
    return (
      esc(c.slice(0, idx)) + "<em>" + esc(t) + "</em>" + esc(c.slice(idx + t.length))
    );
  }

  function renderQueue() {
    var s = current();
    // Show doc suggestions, with matching text siblings first if current is set
    var rows = state.docSuggestions.slice().sort(function (a, b) {
      var ap = Number(a.page_no) - Number(b.page_no);
      if (ap) return ap;
      return String(a.id).localeCompare(String(b.id));
    });
    if (!rows.length) {
      el.qList.innerHTML = '<div class="empty-q">No suggestions for this document.</div>';
      return;
    }
    el.qList.innerHTML = rows
      .map(function (r) {
        var isCur = String(r.id) === String(state.currentId);
        var st = statusOf(r);
        var cls = "sugg";
        if (isCur) cls += " current";
        if (st === "rejected") cls += " done-rej";
        if (st === "accepted") cls += " done-acc";
        var val =
          st === "rejected"
            ? "<s>" + esc(r.text) + "</s>"
            : esc(r.text);
        return (
          '<div class="' +
          cls +
          '" data-id="' +
          r.id +
          '">' +
          '<span class="sw ' +
          swClass(r) +
          '"></span>' +
          '<div class="sugg-text"><div class="val">' +
          val +
          '</div><div class="ctx">' +
          highlightCtx(r.context, r.text) +
          "</div></div>" +
          '<div class="sugg-meta"><div class="conf ' +
          confClass(r) +
          '">' +
          esc(r.confidence) +
          '</div><div class="pg-ref">p.' +
          esc(r.page_no) +
          "</div></div></div>"
        );
      })
      .join("");

    el.qList.querySelectorAll(".sugg").forEach(function (node) {
      node.addEventListener("click", function () {
        state.currentId = String(node.dataset.id);
        var u = new URL(window.location.href);
        u.searchParams.set("doc", String(docId));
        u.searchParams.set("sug", String(state.currentId));
        history.replaceState(null, "", u.toString());
        render();
      });
    });
  }

  function render() {
    renderChrome();
    renderPage();
    renderMatchPanel();
    renderQueue();
  }

  function moveCurrent(delta) {
    var rows = state.docSuggestions.slice().sort(function (a, b) {
      var ap = Number(a.page_no) - Number(b.page_no);
      if (ap) return ap;
      return String(a.id).localeCompare(String(b.id));
    });
    if (!rows.length) return;
    var idx = rows.findIndex(function (r) {
      return String(r.id) === String(state.currentId);
    });
    if (idx < 0) idx = 0;
    else idx = Math.max(0, Math.min(rows.length - 1, idx + delta));
    state.currentId = String(rows[idx].id);
    var u = new URL(window.location.href);
    u.searchParams.set("sug", String(state.currentId));
    history.replaceState(null, "", u.toString());
    render();
  }

  function bind() {
    el.btnReject.addEventListener("click", function () {
      rejectOne();
    });
    el.btnKeep.addEventListener("click", function () {
      keepOne();
    });
    el.btnRejectAll.addEventListener("click", function () {
      rejectAllMatching();
    });
    el.btnUndo.addEventListener("click", function () {
      undoLast();
    });
    var histBtn = document.getElementById("btn-history");
    if (histBtn) {
      histBtn.addEventListener("click", function () {
        if (window.__history && typeof window.__history.open === "function") {
          window.__history.open();
        } else {
          var fab = document.getElementById("hist-fab");
          if (fab) fab.click();
        }
      });
    }
    el.pgPrev.addEventListener("click", function () {
      if (state.pageNo > 1) {
        state.pageNo -= 1;
        // select first mark on that page if any
        var m = state.docSuggestions.find(function (s) {
          return Number(s.page_no) === state.pageNo;
        });
        if (m) state.currentId = String(m.id);
        render();
      }
    });
    el.pgNext.addEventListener("click", function () {
      if (state.pageNo < (state.doc.page_count || 1)) {
        state.pageNo += 1;
        var m = state.docSuggestions.find(function (s) {
          return Number(s.page_no) === state.pageNo;
        });
        if (m) state.currentId = String(m.id);
        render();
      }
    });

    document.addEventListener("keydown", function (ev) {
      var tag = (ev.target && ev.target.tagName) || "";
      if (tag === "INPUT" || tag === "TEXTAREA" || ev.metaKey || ev.ctrlKey || ev.altKey) return;
      var k = ev.key;
      if (k === "r" || k === "R") {
        ev.preventDefault();
        rejectOne();
      } else if (k === "a" || k === "A") {
        ev.preventDefault();
        keepOne();
      } else if (k === "u" || k === "U") {
        ev.preventDefault();
        undoLast();
      } else if (k === "j" || k === "J") {
        ev.preventDefault();
        moveCurrent(1);
      } else if (k === "k" || k === "K") {
        ev.preventDefault();
        moveCurrent(-1);
      } else if (k === "e" || k === "E") {
        var s = current();
        if (s && s.entity_id != null) {
          window.location.href = "/ui/bulk?entity=" + encodeURIComponent(s.entity_id);
        }
      } else if (k === "n" || k === "N") {
        window.location.href = "/ui/add-missed?doc=" + encodeURIComponent(docId);
      }
    });
  }

  async function init() {
    bind();
    try {
      await loadDocMetaFromHtml();
      await loadDocSuggestions();
      // Enrich case_id from suggestion rows if present
      if (!state.doc.case_id && state.docSuggestions[0] && state.docSuggestions[0].case_id) {
        state.doc.case_id = String(state.docSuggestions[0].case_id);
      }
      if (!state.doc.filename && state.docSuggestions[0] && state.docSuggestions[0].filename) {
        state.doc.filename = state.docSuggestions[0].filename.replace(/\.pdf$/i, "");
      }
      if (state.docSuggestions[0] && state.docSuggestions[0].width_pt) {
        state.doc.width_pt = Number(state.docSuggestions[0].width_pt);
      }
      if (state.docSuggestions[0] && state.docSuggestions[0].height_pt) {
        state.doc.height_pt = Number(state.docSuggestions[0].height_pt);
      }
      await loadCaseSuggestions();
      pickCurrent();
      clearErr();
      render();
      window.__REJECT_STATE__ = state;
    } catch (e) {
      console.error(e);
      showErr(String(e.message || e));
      el.pageLoading.textContent = "Failed to load.";
      el.qList.innerHTML =
        '<div class="empty-q">Could not load suggestions. ' +
        esc(e.message || e) +
        "</div>";
    }
  }

  init();
})();
