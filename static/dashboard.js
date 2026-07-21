/* Closure — case document library (S1)
 * Multi-doc selection, folder-glob filter, entity bulk with scope,
 * export, conf bars, per-doc progress rollups.
 */
(function () {
  "use strict";

  const body = document.body;
  if (!body || !body.dataset.caseId) return;

  const C = window.Closure;
  const caseId = body.dataset.caseId;
  const actor = body.dataset.actor || C.DEFAULT_ACTOR;
  const escapeHtml = C.escapeHtml;
  const globToRegExp = C.globToRegExp;

  /** @type {Set<number>} */
  const selectedDocs = new Set();

  const n = (v) => {
    const x = Number(v);
    return Number.isFinite(x) ? x : 0;
  };

  const pct = (part, total) => {
    if (!total || total <= 0) return 0;
    return Math.max(0, Math.min(100, (100 * part) / total));
  };

  const isHumanRequiredKind = (kind) => {
    const k = String(kind || "").toUpperCase();
    return (
      k.indexOf("CITATION") === 0 ||
      k.indexOf("OFFICER") === 0 ||
      k.indexOf("STREET NAME") === 0 ||
      k.indexOf("STREET") === 0
    );
  };

  /** @type {{ undo: null | (() => void | Promise<void>) }} */
  const toastState = { undo: null };

  function toast(msg, opts) {
    const el = document.getElementById("toast");
    const msgEl = document.getElementById("toast-msg");
    const undoBtn = document.getElementById("toast-undo");
    if (!el) return;
    const text = String(msg || "");
    if (msgEl) msgEl.textContent = text;
    else el.textContent = text;
    toastState.undo = opts && typeof opts.undo === "function" ? opts.undo : null;
    if (undoBtn) {
      undoBtn.hidden = !toastState.undo;
    }
    el.classList.add("show");
    clearTimeout(toast._t);
    toast._t = setTimeout(() => {
      el.classList.remove("show");
      toastState.undo = null;
      if (undoBtn) undoBtn.hidden = true;
    }, opts && opts.ms ? opts.ms : 5200);
  }

  async function runToastUndo() {
    if (!toastState.undo) return;
    const fn = toastState.undo;
    toastState.undo = null;
    const undoBtn = document.getElementById("toast-undo");
    if (undoBtn) undoBtn.hidden = true;
    try {
      await fn();
      toast('Restored to pending');
    } catch (err) {
      toast("Undo failed: " + (err && err.message ? err.message : err));
    }
  }

  /* ── glob matcher (via Closure.globToRegExp) ── */

    function rowFilename(row) {
    return String(row.dataset.filename || "").replace(/\.pdf$/i, "");
  }

  function visibleRows() {
    return Array.from(document.querySelectorAll("#doc-table tbody tr[data-doc-id]")).filter(
      (r) => !r.classList.contains("hidden-row")
    );
  }

  function allRows() {
    return Array.from(document.querySelectorAll("#doc-table tbody tr[data-doc-id]"));
  }

  function applyGlob() {
    const input = document.getElementById("glob-filter");
    const pattern = input ? input.value : "";
    const re = globToRegExp(pattern);
    let match = 0;
    allRows().forEach((row) => {
      const name = rowFilename(row);
      const full = name + ".pdf";
      // Also allow path-like patterns: */*F*/*.pdf → match filename containing F
      let ok = true;
      if (re) {
        ok = re.test(name) || re.test(full) || re.test("samples/" + full);
        // If pattern has slashes (folder-glob conceptual), match any path segment
        if (!ok && pattern.indexOf("/") >= 0) {
          const parts = pattern.split("/").filter(Boolean);
          const last = parts[parts.length - 1] || pattern;
          const sub = globToRegExp(last);
          ok = sub ? sub.test(name) || sub.test(full) : name.toLowerCase().indexOf(last.toLowerCase().replace(/\*/g, "")) >= 0;
        }
      } else if (pattern.trim()) {
        // bare text: substring
        const q = pattern.trim().toLowerCase();
        ok = name.toLowerCase().indexOf(q) >= 0;
      }
      row.classList.toggle("hidden-row", !ok);
      if (ok) match += 1;
    });
    const mEl = document.getElementById("glob-match");
    if (mEl) mEl.textContent = match + " matching";
    return match;
  }

  /* ── selection ──────────────────────────────────────────────────────── */
  function syncSelectionUI() {
    const rows = allRows();
    rows.forEach((row) => {
      const id = n(row.dataset.docId);
      const on = selectedDocs.has(id);
      row.classList.toggle("sel", on);
      const cb = row.querySelector(".doc-chk");
      if (cb) cb.checked = on;
    });

    const chip = document.getElementById("sel-chip");
    const bar = document.getElementById("doc-bulkbar");
    const countEl = document.getElementById("doc-sel-count");
    const metaEl = document.getElementById("doc-sel-meta");
    const scopePanel = document.getElementById("scope-panel");
    const scopeN = document.getElementById("scope-n");
    const rollup = document.getElementById("scope-rollup");
    const chkAll = document.getElementById("chk-all");

    const count = selectedDocs.size;
    if (chip) {
      chip.hidden = count === 0;
      chip.textContent = count + " selected";
    }
    if (bar) bar.hidden = count === 0;
    if (countEl) {
      countEl.textContent =
        count === 1 ? "1 document selected" : count + " documents selected";
    }

    let pages = 0;
    let pending = 0;
    let high = 0;
    const rollHtml = [];
    rows.forEach((row) => {
      const id = n(row.dataset.docId);
      if (!selectedDocs.has(id)) return;
      pages += n(row.dataset.pageCount);
      pending += n(row.dataset.pendingCount);
      high += n(row.dataset.highCount);
      const prog = n(row.dataset.progressPct);
      rollHtml.push(
        '<div class="rr"><span class="nm">' +
          escapeHtml(rowFilename(row)) +
          '</span><span class="mt">' +
          n(row.dataset.pendingCount) +
          " pend · " +
          prog +
          '%</span><span class="bar"><i style="width:' +
          prog +
          '%"></i></span></div>'
      );
    });
    if (metaEl) {
      metaEl.textContent =
        count > 0
          ? "· " + pages + " pages · " + pending + " pending · " + high + " HIGH"
          : "";
    }
    if (scopePanel) scopePanel.classList.toggle("on", count > 0);
    if (scopeN) scopeN.textContent = String(count);
    if (rollup) rollup.innerHTML = rollHtml.join("");

    if (chkAll) {
      const vis = visibleRows();
      const allOn =
        vis.length > 0 &&
        vis.every((r) => selectedDocs.has(n(r.dataset.docId)));
      chkAll.checked = allOn;
      chkAll.indeterminate = count > 0 && !allOn;
    }
  }

  function selectMatched() {
    visibleRows().forEach((r) => selectedDocs.add(n(r.dataset.docId)));
    syncSelectionUI();
  }

  function selectAll() {
    allRows().forEach((r) => {
      if (!r.classList.contains("hidden-row")) selectedDocs.add(n(r.dataset.docId));
    });
    syncSelectionUI();
  }

  function selectNone() {
    selectedDocs.clear();
    syncSelectionUI();
  }

  function scopeQuery() {
    if (!selectedDocs.size) return "";
    return "&docs=" + Array.from(selectedDocs).join(",");
  }

  /* ── coverage + header progress ─────────────────────────────────────── */
  function paintCoverage() {
    const accepted = n(body.dataset.acceptedCount);
    const pending = n(body.dataset.pendingCount);
    const rejected = n(body.dataset.rejectedCount);
    const total = n(body.dataset.suggestionCount) || accepted + pending + rejected;
    const resolved = n(body.dataset.resolvedCount) || accepted + rejected;

    const aEl = document.getElementById("seg-accepted");
    const pEl = document.getElementById("seg-pending");
    const rEl = document.getElementById("seg-rejected");
    if (aEl) aEl.style.width = pct(accepted, total).toFixed(2) + "%";
    if (pEl) pEl.style.width = pct(pending, total).toFixed(2) + "%";
    if (rEl) rEl.style.width = pct(rejected, total).toFixed(2) + "%";

    const la = document.getElementById("leg-accepted");
    const lp = document.getElementById("leg-pending");
    const lr = document.getElementById("leg-rejected");
    if (la) la.textContent = accepted + " accepted — ink laid";
    if (lp) lp.textContent = pending + " pending review";
    if (lr) lr.textContent = rejected + " rejected / cleared";

    const pl = document.getElementById("progress-label");
    const pm = document.getElementById("progress-meter");
    if (pl) pl.textContent = resolved + " / " + total;
    if (pm) pm.style.width = pct(resolved, total).toFixed(2) + "%";
  }

  /* ── document conf bars + signed-off ────────────────────────────────── */
  function paintDocRow(row, bands) {
    const total = n(row.dataset.suggestionCount);
    const flagged = n(row.dataset.flaggedCount);
    const pending = n(row.dataset.pendingCount);

    let high = bands && bands.high != null ? bands.high : n(row.dataset.highCount);
    let review = bands && bands.review != null ? bands.review : n(row.dataset.reviewCount);
    let low = bands && bands.flagged != null ? bands.flagged : flagged;

    if (high == null || review == null) {
      low = flagged;
      review = Math.max(0, pending - flagged);
      high = Math.max(0, total - pending);
    }

    const bar = row.querySelector('[data-role="conf-bar"]');
    if (bar && total > 0) {
      const h = bar.querySelector(".cb-h");
      const m = bar.querySelector(".cb-m");
      const l = bar.querySelector(".cb-l");
      if (h) h.style.width = pct(high, total).toFixed(2) + "%";
      if (m) m.style.width = pct(review, total).toFixed(2) + "%";
      if (l) l.style.width = pct(low, total).toFixed(2) + "%";
    }
  }

  function paintDocuments(bandByDoc) {
    const rows = allRows();
    let signed = 0;
    let flaggedDocs = 0;
    let totalFlagged = 0;

    rows.forEach((row) => {
      const id = row.dataset.docId;
      const bands = bandByDoc && bandByDoc[id];
      paintDocRow(row, bands);

      const pending = n(row.dataset.pendingCount);
      const flagged = n(row.dataset.flaggedCount);
      const total = n(row.dataset.suggestionCount);
      if (flagged > 0) {
        flaggedDocs += 1;
        totalFlagged += flagged;
      }
      if (total > 0 && pending === 0) signed += 1;
    });

    const signedEl = document.getElementById("stat-signed-off");
    const docCount = n(body.dataset.docCount) || rows.length;
    if (signedEl) signedEl.textContent = signed + " / " + docCount;

    const flaggedCount = n(body.dataset.flaggedCount) || totalFlagged;
    const banner = document.getElementById("export-banner");
    const btn = document.getElementById("export-btn");
    const bannerDocs = document.getElementById("banner-docs");
    const bannerFlagged = document.getElementById("banner-flagged");

    if (flaggedCount > 0) {
      if (banner) banner.hidden = false;
      if (btn) {
        btn.disabled = true;
        btn.title = "Flagged items require individual judgment before export";
      }
      if (bannerDocs) {
        bannerDocs.textContent =
          flaggedDocs + (flaggedDocs === 1 ? " document" : " documents");
      }
      if (bannerFlagged) {
        bannerFlagged.textContent = flaggedCount + " flagged items";
      }
    } else {
      if (banner) banner.hidden = true;
      if (btn) {
        btn.disabled = false;
        btn.removeAttribute("title");
      }
    }
  }

  /* ── entities ───────────────────────────────────────────────────────── */
  function paintEntities(entityStats) {
    document.querySelectorAll("#ents-card .ent[data-entity-id]").forEach((el) => {
      const kind = el.dataset.kind || "";
      const hit = n(el.dataset.hitCount);
      const human = isHumanRequiredKind(kind);
      const stats = entityStats && entityStats[el.dataset.entityId];
      const pill = el.querySelector('[data-role="ent-pill"]');

      el.classList.toggle("human-req", human);

      if (!pill) return;

      if (human) {
        pill.className = "pill p-flag";
        pill.textContent = "HUMAN REQUIRED";
        pill.title = "Not bulk-acceptable — requires individual judgment";
        return;
      }

      const pending = stats ? n(stats.pending) : hit;
      const accepted = stats ? n(stats.accepted) : 0;
      const rejected = stats ? n(stats.rejected) : 0;

      if (pending === 0 && accepted > 0 && rejected === 0) {
        pill.className = "pill p-acc";
        pill.textContent = "ACCEPTED";
      } else if (pending === 0 && rejected > 0 && accepted === 0) {
        pill.className = "pill p-rej";
        pill.textContent = "REJECTED";
      } else if (pending === 0 && accepted + rejected > 0) {
        pill.className = "pill p-acc";
        pill.textContent = "DECIDED";
      } else {
        pill.className = "pill p-pend";
        pill.textContent = (pending || hit) + " PENDING";
      }
    });
  }

  function wireEntities() {
    document.querySelectorAll("#ents-card .ent[data-entity-id]").forEach((el) => {
      el.addEventListener("click", () => {
        const eid = el.dataset.entityId;
        if (!eid) return;
        window.location.href =
          "/ui/bulk?entity=" +
          encodeURIComponent(eid) +
          "&case=" +
          encodeURIComponent(caseId) +
          scopeQuery();
      });
    });
  }

  /* ── audit ──────────────────────────────────────────────────────────── */
  function renderAuditRows(rows) {
    const list = document.getElementById("audit-list");
    if (!list || !rows || !rows.length) return;

    const frag = document.createDocumentFragment();
    rows.slice(0, 12).forEach((a) => {
      const div = document.createElement("div");
      div.className = "row";
      const action = String(a.action || a.status || "").toLowerCase();
      let cls = "";
      if (action === "accepted" || action === "accept") cls = "acc";
      else if (action === "rejected" || action === "reject") cls = "rej";
      else if (action === "added" || action === "add") cls = "add";

      const ts =
        a.ts_short ||
        (a.ts ? String(a.ts).slice(11, 16) : a.created_at ? String(a.created_at).slice(11, 16) : "—");
      const target = a.target || a.text || a.detail || "";
      const reason = a.reason ? " — " + a.reason : "";
      const who = a.actor || "";

      div.innerHTML =
        '<span class="ts"></span><span class="who"></span><span class="body"></span>';
      div.querySelector(".ts").textContent = ts;
      const aEl = div.querySelector(".who");
      aEl.textContent = action || "event";
      if (cls) aEl.classList.add(cls);
      const bEl = div.querySelector(".body");
      bEl.appendChild(document.createTextNode(target + reason + (who ? " · " : "")));
      if (who) {
        const b = document.createElement("b");
        b.textContent = who;
        bEl.appendChild(b);
      }
      frag.appendChild(div);
    });
    list.innerHTML = "";
    list.appendChild(frag);
  }

  async function loadAudit() {
    try {
      const res = await fetch("/api/cases/" + encodeURIComponent(caseId) + "/audit", {
        headers: { Accept: "application/json" },
      });
      if (!res.ok) return;
      const data = await res.json();
      const rows = Array.isArray(data) ? data : data.events || data.rows || data.audit || [];
      rows.sort((a, b) => {
        const ta = a.ts || a.created_at || a.id || 0;
        const tb = b.ts || b.created_at || b.id || 0;
        if (ta === tb) return (n(b.id) || 0) - (n(a.id) || 0);
        return ta < tb ? 1 : -1;
      });
      renderAuditRows(rows);
    } catch (_) {
      /* SSR audit stays */
    }
  }

  async function loadSuggestions() {
    try {
      const res = await fetch(
        "/api/cases/" + encodeURIComponent(caseId) + "/suggestions",
        { headers: { Accept: "application/json" } }
      );
      if (!res.ok) return null;
      const data = await res.json();
      return Array.isArray(data) ? data : data.suggestions || data.rows || [];
    } catch (_) {
      return null;
    }
  }

  function aggregateSuggestions(rows) {
    const byDoc = {};
    const byEnt = {};
    rows.forEach((s) => {
      const docId = String(s.document_id != null ? s.document_id : s.doc_id);
      const band = String(s.band || "").toLowerCase();
      const status = String(s.status || "pending").toLowerCase();
      const entId =
        s.entity_id != null && s.entity_id !== "" ? String(s.entity_id) : null;

      if (!byDoc[docId]) byDoc[docId] = { high: 0, review: 0, flagged: 0 };
      if (band === "high") byDoc[docId].high += 1;
      else if (band === "review") byDoc[docId].review += 1;
      else if (band === "flagged") byDoc[docId].flagged += 1;
      else {
        const c = n(s.confidence);
        if (c >= 90) byDoc[docId].high += 1;
        else if (c >= 60) byDoc[docId].review += 1;
        else byDoc[docId].flagged += 1;
      }

      if (entId) {
        if (!byEnt[entId]) byEnt[entId] = { pending: 0, accepted: 0, rejected: 0 };
        if (status === "accepted") byEnt[entId].accepted += 1;
        else if (status === "rejected") byEnt[entId].rejected += 1;
        else byEnt[entId].pending += 1;
      }
    });
    return { byDoc, byEnt };
  }

  /* ── apply live suggestion rows onto library + funnel chrome ───────── */
  function applySuggestionSnapshot(rows) {
    if (!rows || !rows.length) return;
    const byDoc = {};
    rows.forEach((s) => {
      const id = String(s.document_id);
      if (!byDoc[id]) {
        byDoc[id] = {
          pending: 0,
          accepted: 0,
          rejected: 0,
          high: 0,
          highPending: 0,
          review: 0,
          reviewPending: 0,
          flagged: 0,
          total: 0,
        };
      }
      byDoc[id].total += 1;
      const st = String(s.status || "pending").toLowerCase();
      if (st === "pending") byDoc[id].pending += 1;
      if (st === "accepted") byDoc[id].accepted += 1;
      if (st === "rejected") byDoc[id].rejected += 1;
      const band = String(s.band || "").toLowerCase();
      if (band === "high") {
        byDoc[id].high += 1;
        if (st === "pending") byDoc[id].highPending += 1;
      } else if (band === "review") {
        byDoc[id].review += 1;
        if (st === "pending") byDoc[id].reviewPending += 1;
      } else if (band === "flagged") {
        if (st === "pending") byDoc[id].flagged += 1;
      }
    });

    allRows().forEach((row) => {
      const id = String(row.dataset.docId);
      const d = byDoc[id];
      if (!d) return;
      row.dataset.pendingCount = String(d.pending);
      row.dataset.acceptedCount = String(d.accepted);
      row.dataset.rejectedCount = String(d.rejected);
      row.dataset.highCount = String(d.highPending);
      row.dataset.reviewCount = String(d.review);
      row.dataset.flaggedCount = String(d.flagged);
      row.dataset.suggestionCount = String(d.total);
      const resolved = d.accepted + d.rejected;
      row.dataset.progressPct = String(d.total ? Math.round((100 * resolved) / d.total) : 0);
      row.classList.toggle("flagged-row", d.flagged > 0);

      const statusEl = row.querySelector("[data-role=doc-status]");
      if (statusEl) {
        if (d.flagged > 0) {
          statusEl.className = "doc-status st-blocked";
          statusEl.textContent = d.flagged + " flagged";
        } else if (d.pending === 0 && d.total > 0) {
          statusEl.className = "doc-status st-done";
          statusEl.textContent = "Signed off";
        } else if (d.total === 0) {
          statusEl.className = "doc-status st-empty";
          statusEl.textContent = "—";
        } else {
          statusEl.className = "doc-status st-review";
          statusEl.textContent = d.pending + " pending";
        }
      }
      const track = row.querySelector(".prog-track i");
      if (track) track.style.width = row.dataset.progressPct + "%";
      const progLabel = row.querySelector(".progress");
      if (progLabel) progLabel.textContent = row.dataset.progressPct + "%";

      const actions = row.querySelector(".row-actions");
      if (actions) {
        let resolveBtn = actions.querySelector("[data-role=resolve-flagged]");
        if (d.flagged > 0) {
          if (!resolveBtn) {
            resolveBtn = document.createElement("a");
            resolveBtn.className = "btn small danger";
            resolveBtn.setAttribute("data-role", "resolve-flagged");
            resolveBtn.href = "/documents/" + id;
            actions.insertBefore(resolveBtn, actions.firstChild);
          }
          resolveBtn.textContent = "Resolve " + d.flagged;
          resolveBtn.title = "Resolve " + d.flagged + " flagged";
        } else if (resolveBtn) {
          resolveBtn.remove();
        }
      }
    });

    const { byDoc: bands, byEnt } = aggregateSuggestions(rows);
    paintDocuments(bands);
    paintEntities(byEnt);

    let pend = 0;
    let acc = 0;
    let rej = 0;
    let flag = 0;
    let highPend = 0;
    let reviewPend = 0;
    rows.forEach((s) => {
      const st = String(s.status || "pending").toLowerCase();
      if (st === "pending") pend += 1;
      else if (st === "accepted") acc += 1;
      else if (st === "rejected") rej += 1;
      if (String(s.band).toLowerCase() === "flagged" && st === "pending") flag += 1;
      if (String(s.band).toLowerCase() === "high" && st === "pending") highPend += 1;
      if (String(s.band).toLowerCase() === "review" && st === "pending") reviewPend += 1;
    });
    body.dataset.pendingCount = String(pend);
    body.dataset.acceptedCount = String(acc);
    body.dataset.rejectedCount = String(rej);
    body.dataset.flaggedCount = String(flag);
    body.dataset.resolvedCount = String(acc + rej);
    body.dataset.suggestionCount = String(rows.length);
    body.dataset.highPending = String(highPend);
    body.dataset.reviewPending = String(reviewPend);

    const sp = document.getElementById("stat-pending");
    const sa = document.getElementById("stat-accepted");
    const sf = document.getElementById("stat-flagged");
    if (sp) sp.textContent = String(pend);
    if (sa) sa.textContent = String(acc);
    if (sf) sf.textContent = String(flag);
    paintCoverage();
    paintFunnelChrome(rows);
    syncSelectionUI();
  }

  function paintFunnelChrome(rows) {
    const highPend = n(body.dataset.highPending);
    const flag = n(body.dataset.flaggedCount);
    const reviewPend = n(body.dataset.reviewPending);

    const highBtn = document.getElementById("btn-accept-high-case");
    const highN = document.getElementById("high-case-n");
    if (highN) highN.textContent = String(highPend);
    if (highBtn) highBtn.hidden = highPend <= 0;

    const resBtn = document.getElementById("btn-resolve-flagged");
    const resN = document.getElementById("resolve-flagged-n");
    if (resN) resN.textContent = String(flag);
    if (resBtn) resBtn.hidden = flag <= 0;

    // first pending / first flagged deep links
    const openNext = document.getElementById("btn-open-first-pending");
    if (openNext) {
      let target = null;
      const flaggedRow = document.querySelector("#doc-table tr.flagged-row");
      const pendingRow = allRows().find((r) => n(r.dataset.pendingCount) > 0);
      target = flaggedRow || pendingRow;
      if (target) openNext.href = "/documents/" + target.dataset.docId;
      else openNext.href = "#library";
    }

    // export checklist
    const ckFlag = document.getElementById("ck-flagged");
    const ckFlagText = document.getElementById("ck-flagged-text");
    const ckReview = document.getElementById("ck-review");
    const ckReviewText = document.getElementById("ck-review-text");
    const ckReady = document.getElementById("ck-ready");
    if (ckFlagText) {
      ckFlagText.textContent =
        flag > 0
          ? flag + " pending flagged — blocks export"
          : "0 pending flagged — clear";
    }
    if (ckFlag) ckFlag.className = "ck " + (flag > 0 ? "block" : "ok");
    if (ckReviewText) {
      ckReviewText.textContent =
        reviewPend + " pending REVIEW" + (reviewPend ? " (optional warn)" : "");
    }
    if (ckReview) ckReview.className = "ck " + (reviewPend > 0 ? "warn" : "ok");
    if (ckReady) ckReady.hidden = flag > 0;

    // bulkbar HIGH label with live count
    const bulkHigh = document.getElementById("btn-bulk-high");
    if (bulkHigh && selectedDocs.size) {
      let highInSel = 0;
      allRows().forEach((row) => {
        if (selectedDocs.has(n(row.dataset.docId))) highInSel += n(row.dataset.highCount);
      });
      bulkHigh.textContent =
        highInSel > 0
          ? "Accept HIGH in selection (" + highInSel + ")"
          : "Accept HIGH in selection";
      bulkHigh.disabled = highInSel === 0;
    }

    // cache first flagged suggestion for deep-link
    if (rows && rows.length) {
      const firstFlag = rows.find(
        (s) =>
          String(s.band).toLowerCase() === "flagged" &&
          String(s.status || "pending").toLowerCase() === "pending"
      );
      body.dataset.firstFlaggedDoc = firstFlag
        ? String(firstFlag.document_id)
        : "";
      body.dataset.firstFlaggedSug = firstFlag ? String(firstFlag.id) : "";
      body.dataset.firstFlaggedPage = firstFlag
        ? String(firstFlag.page_no || 1)
        : "";
    }
  }

  function jumpToFlagged() {
    const docId = body.dataset.firstFlaggedDoc;
    const sugId = body.dataset.firstFlaggedSug;
    if (docId && sugId) {
      // Prefer reject shell for FP judgment path; falls back to review anchor.
      window.location.href =
        "/ui/reject?doc=" +
        encodeURIComponent(docId) +
        "&sug=" +
        encodeURIComponent(sugId);
      return;
    }
    const first = document.querySelector("#doc-table tr.flagged-row");
    if (first) {
      first.scrollIntoView({ behavior: "smooth", block: "center" });
      first.classList.add("sel");
      return;
    }
    const lib = document.getElementById("library");
    if (lib) lib.scrollIntoView({ behavior: "smooth", block: "start" });
  }

  function openHistory() {
    if (!C.openHistory()) toast("History panel not mounted on this page");
  }

  /* ── bulk HIGH accept across selected docs (or whole case) ─────────── */
  async function acceptHighInDocs(docIds, reason) {
    const ids = Array.from(docIds || []);
    if (!ids.length) return { ok: 0, fail: 0, docIds: [] };
    let ok = 0;
    let fail = 0;
    const succeeded = [];
    for (const docId of ids) {
      try {
        const url =
          "/api/documents/" +
          docId +
          "/band/high/decision?status=accepted&actor=" +
          encodeURIComponent(actor) +
          "&reason=" +
          encodeURIComponent(reason || "bulk HIGH accept");
        const res = await C.postJson(url);
        if (res.ok || res.status === 200 || res.status === 204) {
          ok += 1;
          succeeded.push(docId);
        } else fail += 1;
      } catch (_) {
        fail += 1;
      }
    }
    return { ok, fail, docIds: succeeded };
  }

  async function undoHighInDocs(docIds) {
    for (const docId of docIds || []) {
      try {
        const url =
          "/api/documents/" +
          docId +
          "/band/high/decision?status=pending&actor=" +
          encodeURIComponent(actor) +
          "&reason=" +
          encodeURIComponent("undo bulk HIGH");
        await C.postJson(url);
      } catch (_) {
        /* best-effort */
      }
    }
    const rows = await loadSuggestions();
    if (rows) applySuggestionSnapshot(rows);
    loadAudit();
  }

  async function acceptHighInSelection() {
    if (!selectedDocs.size) return;
    const btn = document.getElementById("btn-bulk-high");
    if (btn) {
      btn.disabled = true;
      btn.textContent = "Accepting…";
    }
    try {
      const result = await acceptHighInDocs(
        selectedDocs,
        "bulk HIGH in library selection"
      );
      toast(
        "Accepted HIGH in " +
          result.ok +
          " document" +
          (result.ok === 1 ? "" : "s") +
          (result.fail ? " · " + result.fail + " failed" : ""),
        {
          undo:
            result.docIds.length > 0
              ? () => undoHighInDocs(result.docIds)
              : null,
          ms: 8000,
        }
      );
      const rows = await loadSuggestions();
      if (rows) applySuggestionSnapshot(rows);
      loadAudit();
    } finally {
      if (btn) {
        btn.disabled = false;
        const highInSel = Array.from(selectedDocs).reduce((sum, id) => {
          const row = document.querySelector(
            '#doc-table tr[data-doc-id="' + id + '"]'
          );
          return sum + (row ? n(row.dataset.highCount) : 0);
        }, 0);
        btn.textContent =
          highInSel > 0
            ? "Accept HIGH in selection (" + highInSel + ")"
            : "Accept HIGH in selection";
        btn.disabled = highInSel === 0;
      }
    }
  }

  async function acceptHighInCase() {
    const btn = document.getElementById("btn-accept-high-case");
    const ids = allRows()
      .filter((r) => n(r.dataset.highCount) > 0)
      .map((r) => n(r.dataset.docId));
    if (!ids.length) {
      toast("No HIGH pending in this case");
      return;
    }
    if (btn) {
      btn.disabled = true;
      btn.textContent = "Accepting HIGH…";
    }
    try {
      const result = await acceptHighInDocs(ids, "accept all HIGH in case");
      toast(
        "Accepted all HIGH in case · " +
          result.ok +
          " document" +
          (result.ok === 1 ? "" : "s") +
          (result.fail ? " · " + result.fail + " failed" : ""),
        {
          undo:
            result.docIds.length > 0
              ? () => undoHighInDocs(result.docIds)
              : null,
          ms: 8000,
        }
      );
      const rows = await loadSuggestions();
      if (rows) applySuggestionSnapshot(rows);
      loadAudit();
    } finally {
      if (btn) {
        btn.disabled = false;
        const hp = n(body.dataset.highPending);
        btn.innerHTML =
          'Accept all HIGH in case (<span id="high-case-n">' + hp + "</span>)";
        btn.hidden = hp <= 0;
      }
    }
  }

  /* ── export ─────────────────────────────────────────────────────────── */
  /* GET export_plan → {blocked, export_sql}; hard-stop if blocked (no POST,
     no files). When clear, POST {sql: export_sql} — the server built that
     sentence from LIVE accepted boxes (v_export_plans), the client only
     echoes it across the foldable-param wall. The response is the redaction
     relation itself (one row per document); we count rows here. */
  async function doExport() {
    const btn = document.getElementById("export-btn");
    const out = document.getElementById("export-result");
    if (btn && btn.disabled) return;

    if (btn) {
      btn.disabled = true;
      btn.textContent = "Exporting…";
    }
    if (out) {
      out.classList.remove("show", "err");
      out.textContent = "";
    }

    const planUrl = "/api/cases/" + encodeURIComponent(caseId) + "/export_plan";
    const exportUrl =
      "/api/cases/" +
      encodeURIComponent(caseId) +
      "/export?actor=" +
      encodeURIComponent(actor);

    try {
      const planRes = await fetch(planUrl, { headers: { Accept: "application/json" } });
      const planText = await planRes.text();
      let plan;
      try {
        plan = JSON.parse(planText);
      } catch (_) {
        plan = null;
      }
      if (Array.isArray(plan) && plan.length === 1) plan = plan[0];

      if (!planRes.ok || !plan) {
        if (out) {
          out.classList.add("show", "err");
          out.textContent = planText || "export_plan failed";
        }
        toast("Export plan failed (" + planRes.status + ")");
        return;
      }

      if (plan.blocked) {
        // Blocked plans never POST: the server's sentence is the no-op
        // anyway (construction-gated), so there is nothing to run.
        if (out) {
          out.classList.add("show", "err");
          out.textContent = JSON.stringify(plan, null, 2);
        }
        toast("Export blocked: flagged items require individual judgment · wrote 0 files");
        return;
      }

      const res = await fetch(exportUrl, {
        method: "POST",
        headers: { Accept: "application/json", "Content-Type": "application/json" },
        body: JSON.stringify({ sql: plan.export_sql || "" }),
      });
      const text = await res.text();
      let rows;
      try {
        rows = JSON.parse(text);
      } catch (_) {
        rows = null;
      }
      if (rows && !Array.isArray(rows)) rows = [rows];
      const exported = Array.isArray(rows)
        ? rows.filter((r) => r && r.document_id != null).length
        : 0;

      if (out) {
        out.classList.add("show");
        if (!res.ok || exported === 0) out.classList.add("err");
        out.textContent = Array.isArray(rows) ? JSON.stringify(rows, null, 2) : text;
      }

      if (res.ok && exported > 0) {
        toast("Exported " + exported + " redacted documents · redactions laid");
      } else {
        toast("Export failed (" + res.status + ")");
      }
    } catch (err) {
      if (out) {
        out.classList.add("show", "err");
        out.textContent = String(err && err.message ? err.message : err);
      }
      toast("Export request failed");
    } finally {
      if (btn) {
        btn.textContent = "Export redacted case…";
        if (n(body.dataset.flaggedCount) > 0) btn.disabled = true;
        else btn.disabled = false;
      }
    }
  }

  function wireLibrary() {
    const glob = document.getElementById("glob-filter");
    if (glob) {
      glob.addEventListener("input", () => {
        applyGlob();
      });
      glob.addEventListener("keydown", (e) => {
        if (e.key === "Enter") {
          e.preventDefault();
          selectMatched();
        }
      });
    }

    const btnMatched = document.getElementById("btn-select-matched");
    const btnAll = document.getElementById("btn-select-all");
    const btnNone = document.getElementById("btn-select-none");
    if (btnMatched) btnMatched.addEventListener("click", selectMatched);
    if (btnAll) btnAll.addEventListener("click", selectAll);
    if (btnNone) btnNone.addEventListener("click", selectNone);

    const chkAll = document.getElementById("chk-all");
    if (chkAll) {
      chkAll.addEventListener("change", () => {
        if (chkAll.checked) selectAll();
        else selectNone();
      });
    }

    document.querySelectorAll(".doc-chk").forEach((cb) => {
      cb.addEventListener("click", (e) => e.stopPropagation());
      cb.addEventListener("change", () => {
        const id = n(cb.dataset.docId || cb.closest("tr")?.dataset.docId);
        if (cb.checked) selectedDocs.add(id);
        else selectedDocs.delete(id);
        syncSelectionUI();
      });
    });

    // row click (not on checkbox/link) toggles select
    allRows().forEach((row) => {
      row.addEventListener("click", (e) => {
        if (e.target.closest("a,button,input,.row-actions")) return;
        const id = n(row.dataset.docId);
        if (selectedDocs.has(id)) selectedDocs.delete(id);
        else selectedDocs.add(id);
        syncSelectionUI();
      });
    });

    const clear = document.getElementById("btn-clear-docs");
    if (clear) clear.addEventListener("click", selectNone);

    const openBulk = document.getElementById("btn-open-scoped-bulk");
    if (openBulk) {
      openBulk.addEventListener("click", () => {
        window.location.href =
          "/ui/bulk?case=" + encodeURIComponent(caseId) + scopeQuery();
      });
    }

    const highBtn = document.getElementById("btn-bulk-high");
    if (highBtn) highBtn.addEventListener("click", () => void acceptHighInSelection());

    const importBtns = [
      document.getElementById("btn-import"),
      document.getElementById("btn-import-stub"),
    ];
    importBtns.forEach((b) => {
      if (!b) return;
      b.addEventListener("click", () => {
        toast("Import stub — PDFs load from samples/*.pdf at boot");
      });
    });
  }

  function wireExport() {
    const btn = document.getElementById("export-btn");
    if (!btn) return;
    btn.addEventListener("click", (e) => {
      e.preventDefault();
      if (btn.disabled) return;
      doExport();
    });
  }

  function wireJump() {
    ["jump-flagged", "ck-flagged-link", "stat-flagged-link", "btn-resolve-flagged"].forEach(
      (id) => {
        const a = document.getElementById(id);
        if (!a) return;
        a.addEventListener("click", (e) => {
          e.preventDefault();
          jumpToFlagged();
        });
      }
    );

    const pendLink = document.getElementById("stat-pending-link");
    if (pendLink) {
      pendLink.addEventListener("click", (e) => {
        e.preventDefault();
        const lib = document.getElementById("library");
        if (lib) lib.scrollIntoView({ behavior: "smooth", block: "start" });
      });
    }
    const entLink = document.getElementById("stat-entities-link");
    if (entLink) {
      entLink.addEventListener("click", (e) => {
        e.preventDefault();
        const card = document.getElementById("ents-card");
        if (card) card.scrollIntoView({ behavior: "smooth", block: "start" });
      });
    }
    const accLink = document.getElementById("stat-accepted-link");
    if (accLink) {
      accLink.addEventListener("click", (e) => {
        e.preventDefault();
        const cov = document.getElementById("coverage");
        if (cov) cov.scrollIntoView({ behavior: "smooth", block: "center" });
      });
    }
  }

  function wireFunnel() {
    const highCase = document.getElementById("btn-accept-high-case");
    if (highCase) highCase.addEventListener("click", () => void acceptHighInCase());

    const histBtn = document.getElementById("btn-history");
    const histOpen = document.getElementById("btn-open-history");
    [histBtn, histOpen].forEach((b) => {
      if (b) b.addEventListener("click", openHistory);
    });

    const toastUndo = document.getElementById("toast-undo");
    if (toastUndo) toastUndo.addEventListener("click", () => void runToastUndo());

    const ckExport = document.getElementById("ck-export-btn");
    if (ckExport) {
      ckExport.addEventListener("click", () => {
        const btn = document.getElementById("export-btn");
        if (btn && !btn.disabled) doExport();
        else jumpToFlagged();
      });
    }

    // seed HIGH count from SSR row data before API returns
    let highPend = 0;
    allRows().forEach((r) => {
      highPend += n(r.dataset.highCount);
    });
    body.dataset.highPending = String(highPend);
    paintFunnelChrome(null);
  }

  function wireKeyboard() {
    document.addEventListener("keydown", (e) => {
      if (C.isEditableTarget(e.target)) return;
      if (e.metaKey || e.ctrlKey || e.altKey) return;

      const k = e.key;
      if (k === "/") {
        e.preventDefault();
        const glob = document.getElementById("glob-filter");
        if (glob) {
          glob.focus();
          glob.select();
        }
        return;
      }
      if (k === "o" || k === "O") {
        e.preventDefault();
        if (selectedDocs.size) {
          const id = Array.from(selectedDocs)[0];
          window.location.href = "/documents/" + id;
          return;
        }
        const openNext = document.getElementById("btn-open-first-pending");
        if (openNext && openNext.href) window.location.href = openNext.href;
        return;
      }
      // History owns plain `h` (history.js capture). Shift+A = accept all HIGH.
      if ((k === "a" || k === "A") && e.shiftKey) {
        e.preventDefault();
        void acceptHighInCase();
        return;
      }
      if (k === "f" || k === "F") {
        e.preventDefault();
        jumpToFlagged();
        return;
      }
      if (k === "u" || k === "U") {
        e.preventDefault();
        if (toastState.undo) void runToastUndo();
        else if (window.__history && typeof window.__history.undo === "function") {
          void window.__history.undo();
        } else {
          toast("Nothing to undo");
        }
      }
    });
  }

  /* ── boot ───────────────────────────────────────────────────────────── */
  async function init() {
    paintCoverage();
    paintDocuments(null);
    paintEntities(null);
    wireExport();
    wireJump();
    wireLibrary();
    wireEntities();
    wireFunnel();
    wireKeyboard();
    applyGlob();
    syncSelectionUI();

    const [rows] = await Promise.all([loadSuggestions(), loadAudit()]);
    if (rows && rows.length) {
      applySuggestionSnapshot(rows);
    } else {
      paintFunnelChrome(null);
    }

    // expose for verification
    window.__library = {
      selected: () => Array.from(selectedDocs),
      selectMatched,
      selectAll,
      selectNone,
      acceptHigh: acceptHighInSelection,
      acceptHighCase: acceptHighInCase,
      jumpToFlagged,
      openHistory,
      applyGlob,
      toast,
    };
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", init);
  } else {
    init();
  }
})();
