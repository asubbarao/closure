/**
 * Closure — possible missed redactions (remainder scan)
 *
 * Loads GET /api/documents/:id/missed (or case-level), paints a queue panel,
 * and one-tap POSTs the existing add route so hits become accepted manual
 * suggestions.
 *
 * Mounts on review pages (body[data-doc-id]) or standalone /ui/missed.
 */
(function () {
  "use strict";

  const ACTOR = "A. Subbarao";
  const PANEL_ID = "remainder-panel";
  const STYLE_ID = "remainder-panel-styles";

  function bootData() {
    try {
      const el = document.getElementById("boot-data");
      if (el) return JSON.parse(el.textContent);
    } catch (_) {}
    return {};
  }

  const boot = bootData();
  const body = document.body;
  const docId = Number(boot.docId || body.dataset.docId || 0);
  const caseId = Number(boot.caseId || body.dataset.caseId || 0);
  const pageNo = Number(boot.pageNo || body.dataset.pageNo || 1);
  const actor = boot.actor || body.dataset.actor || ACTOR;
  const standalone = body.dataset.remainderStandalone === "1";

  /** @type {Array} */
  let items = [];
  const addedIds = new Set();
  let inflight = new Set();

  function escapeHtml(str) {
    return String(str == null ? "" : str)
      .replace(/&/g, "&amp;")
      .replace(/</g, "&lt;")
      .replace(/>/g, "&gt;")
      .replace(/"/g, "&quot;");
  }

  function toast(msg, isErr) {
    let el = document.getElementById("rm-toast");
    if (!el) {
      el = document.createElement("div");
      el.id = "rm-toast";
      el.className = "rm-toast";
      el.setAttribute("role", "status");
      document.body.appendChild(el);
    }
    el.textContent = msg;
    el.className = "rm-toast show" + (isErr ? " err" : "");
    clearTimeout(el._t);
    el._t = setTimeout(function () {
      el.classList.remove("show");
    }, isErr ? 6000 : 3200);
  }

  function ensureStyles() {
    if (document.getElementById(STYLE_ID)) return;
    const css = `
.rm-panel{border-top:1px solid var(--line,#D6DCE3);background:var(--panel,#fff);flex-shrink:0;max-height:42%;display:flex;flex-direction:column;min-height:0}
.rm-head{display:flex;align-items:baseline;justify-content:space-between;gap:10px;padding:10px 14px 6px;flex-shrink:0}
.rm-head h3{font-size:12px;font-weight:700;letter-spacing:.04em;text-transform:uppercase;color:var(--ink2,#5A6577);margin:0}
.rm-head .rm-count{font-family:var(--mono,'IBM Plex Mono',ui-monospace,monospace);font-size:11px;font-weight:700;color:var(--acc,#1D4ED8);background:var(--accbg,#EBF0FE);border:1px solid #C5D4F8;border-radius:10px;padding:1px 8px}
.rm-note{font-size:11px;color:var(--ink2,#5A6577);padding:0 14px 8px;line-height:1.4;flex-shrink:0}
.rm-note b{color:var(--ink,#1A2230)}
.rm-list{overflow-y:auto;flex:1;padding:0 10px 10px;min-height:0}
.rm-empty{padding:14px 8px;font-size:12px;color:var(--ink3,#8A94A6);line-height:1.5}
.rm-row{display:flex;align-items:center;gap:8px;padding:8px 8px;border:1px solid var(--line,#D6DCE3);border-radius:6px;margin-bottom:6px;background:#FAFBFD}
.rm-row:hover{border-color:var(--acc,#1D4ED8);background:var(--accbg,#EBF0FE)}
.rm-row.rm-added{background:var(--okbg,#E7F5EE);border-color:#BFE3CF}
.rm-sw{width:7px;height:22px;border-radius:2px;background:var(--acc,#1D4ED8);flex-shrink:0}
.rm-row.rm-added .rm-sw{background:var(--ok,#087443)}
.rm-body{flex:1;min-width:0}
.rm-val{font-family:var(--mono,'IBM Plex Mono',ui-monospace,monospace);font-size:12.5px;font-weight:600;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;color:var(--ink,#1A2230)}
.rm-meta{font-size:11px;color:var(--ink2,#5A6577);white-space:nowrap;overflow:hidden;text-overflow:ellipsis;margin-top:1px}
.rm-badge{font-size:9.5px;font-weight:700;letter-spacing:.04em;text-transform:uppercase;color:var(--acc,#1D4ED8);background:rgba(29,78,216,.1);padding:2px 7px;border-radius:8px;flex-shrink:0;white-space:nowrap}
.rm-row.rm-added .rm-badge{color:var(--ok,#087443);background:rgba(8,116,67,.1)}
.rm-add{font-family:var(--sans,'IBM Plex Sans',system-ui,sans-serif);font-weight:600;font-size:11px;padding:5px 10px;border-radius:6px;border:1px solid var(--ink,#1A2230);background:var(--ink,#1A2230);color:#fff;cursor:pointer;flex-shrink:0;white-space:nowrap}
.rm-add:hover{opacity:.9}
.rm-add:disabled{opacity:.45;cursor:not-allowed}
.rm-add.rm-done{background:transparent;border-color:#BFE3CF;color:var(--ok,#087443)}
.rm-toast{position:fixed;bottom:28px;left:50%;transform:translateX(-50%);z-index:120;background:var(--ink,#1A2230);color:#fff;padding:10px 14px;border-radius:6px;font-size:13px;font-weight:500;box-shadow:0 8px 28px rgba(26,34,48,.28);max-width:min(520px,92vw);display:none}
.rm-toast.show{display:block}
.rm-toast.err{background:var(--rej,#B42318)}
.rm-mark{position:absolute;border-radius:2px;z-index:12;background:rgba(29,78,216,.14);outline:1.5px dashed var(--acc,#1D4ED8);pointer-events:none}
.rm-mark.rm-laid{background:var(--black,#0B0E14);outline:none}
`;
    const style = document.createElement("style");
    style.id = STYLE_ID;
    style.textContent = css;
    document.head.appendChild(style);
  }

  function ensurePanel() {
    let panel = document.getElementById(PANEL_ID);
    if (panel) return panel;

    ensureStyles();
    panel = document.createElement("aside");
    panel.id = PANEL_ID;
    panel.className = "rm-panel";
    panel.setAttribute("aria-label", "Possible missed redactions");
    panel.innerHTML =
      '<div class="rm-head">' +
      "<h3>Possible missed redactions</h3>" +
      '<span class="rm-count" id="rm-count">…</span>' +
      "</div>" +
      '<div class="rm-note">Remainder scan — residual PII not covered by accepted/pending suggestions. ' +
      "One-tap adds a <b>manual · accepted</b> redaction.</div>" +
      '<div class="rm-list" id="rm-list"><div class="rm-empty">Loading remainder scan…</div></div>';

    // Prefer the review queue column; fall back to body.
    const queue = document.querySelector("aside.queue");
    if (queue) {
      // Insert above the keyboard legend so the main suggestion list stays primary.
      const keys = queue.querySelector(".keys");
      if (keys) queue.insertBefore(panel, keys);
      else queue.appendChild(panel);
    } else {
      document.body.appendChild(panel);
    }
    return panel;
  }

  function apiUrl() {
    if (docId > 0) return "/api/documents/" + docId + "/missed";
    if (caseId > 0) return "/api/cases/" + caseId + "/missed";
    return null;
  }

  async function fetchJson(url, opts) {
    const res = await fetch(url, opts);
    let data = null;
    const raw = await res.text();
    try {
      data = raw ? JSON.parse(raw) : null;
    } catch (_) {
      data = raw;
    }
    return { ok: res.ok, status: res.status, data: data, raw: raw };
  }

  function normalizeRows(data) {
    if (!data) return [];
    if (Array.isArray(data)) return data;
    // quackapi sometimes wraps: {rows:[...]} or single object
    if (Array.isArray(data.rows)) return data.rows;
    if (data.id != null || data.text != null) return [data];
    // object map of columns → parallel arrays (rare)
    if (data.document_id && Array.isArray(data.document_id)) {
      const n = data.document_id.length;
      const rows = [];
      for (let i = 0; i < n; i++) {
        const row = {};
        Object.keys(data).forEach(function (k) {
          row[k] = Array.isArray(data[k]) ? data[k][i] : data[k];
        });
        rows.push(row);
      }
      return rows;
    }
    return [];
  }

  function kindLabel(k) {
    return String(k || "PII").replace(/ · /g, " · ");
  }

  function paintMarks(rows) {
    const layer = document.getElementById("marks-layer");
    const pageEl = document.getElementById("pdf-page");
    if (!layer || !pageEl) return;
    // Remove prior remainder marks
    layer.querySelectorAll(".rm-mark").forEach(function (n) {
      n.remove();
    });
    const scale = Number(
      (boot.scale != null ? boot.scale : body.dataset.scale) || 1
    );
    const currentPage = Number(pageEl.dataset.pageNo || pageNo);
    rows.forEach(function (r) {
      if (Number(r.page) !== currentPage) return;
      const div = document.createElement("div");
      const laid = addedIds.has(Number(r.id));
      div.className = "rm-mark" + (laid ? " rm-laid" : "");
      div.style.left = Number(r.x0) * scale + "px";
      div.style.top = Number(r.y0) * scale + "px";
      div.style.width = Math.max(2, (Number(r.x1) - Number(r.x0)) * scale) + "px";
      div.style.height = Math.max(2, (Number(r.y1) - Number(r.y0)) * scale) + "px";
      div.title = (r.text || "") + " · " + (r.why || r.kind || "missed");
      div.dataset.rmId = String(r.id);
      layer.appendChild(div);
    });
  }

  function renderList() {
    const list = document.getElementById("rm-list");
    const count = document.getElementById("rm-count");
    if (!list) return;

    // Prefer current page first, then other pages.
    const sorted = items.slice().sort(function (a, b) {
      const ap = Number(a.page) === pageNo ? 0 : 1;
      const bp = Number(b.page) === pageNo ? 0 : 1;
      if (ap !== bp) return ap - bp;
      if (a.page !== b.page) return Number(a.page) - Number(b.page);
      return Number(a.y0) - Number(b.y0) || Number(a.x0) - Number(b.x0);
    });

    if (count) count.textContent = String(sorted.length);

    if (sorted.length === 0) {
      list.innerHTML =
        '<div class="rm-empty">No residual PII on the remainder for this document. Spaced/dotted SSNs, dotted phones, and misspelled roster names would appear here.</div>';
      paintMarks([]);
      return;
    }

    list.innerHTML = sorted
      .map(function (r) {
        const id = Number(r.id);
        const done = addedIds.has(id);
        const meta =
          kindLabel(r.kind) +
          " · p." +
          r.page +
          (r.detector ? " · " + r.detector : "") +
          (r.score != null ? " · " + Number(r.score).toFixed(0) : "");
        return (
          '<div class="rm-row' +
          (done ? " rm-added" : "") +
          '" data-rm-id="' +
          id +
          '">' +
          '<span class="rm-sw"></span>' +
          '<div class="rm-body">' +
          '<div class="rm-val">' +
          escapeHtml(r.text) +
          "</div>" +
          '<div class="rm-meta" title="' +
          escapeHtml(r.why || "") +
          '">' +
          escapeHtml(meta) +
          (r.why ? " · " + escapeHtml(r.why) : "") +
          "</div>" +
          "</div>" +
          '<span class="rm-badge">' +
          escapeHtml(kindLabel(r.kind)) +
          "</span>" +
          '<button type="button" class="rm-add' +
          (done ? " rm-done" : "") +
          '" data-rm-id="' +
          id +
          '"' +
          (done ? " disabled" : "") +
          ">" +
          (done ? "Added ✓" : "Add as redaction") +
          "</button>" +
          "</div>"
        );
      })
      .join("");

    list.querySelectorAll(".rm-add:not(.rm-done)").forEach(function (btn) {
      btn.addEventListener("click", function (ev) {
        ev.preventDefault();
        ev.stopPropagation();
        const id = Number(btn.getAttribute("data-rm-id"));
        const row = items.find(function (x) {
          return Number(x.id) === id;
        });
        if (row) void addAsRedaction(row, btn);
      });
    });

    paintMarks(sorted);
  }

  async function addAsRedaction(row, btn) {
    const id = Number(row.id);
    if (!docId || inflight.has(id) || addedIds.has(id)) return;
    inflight.add(id);
    if (btn) {
      btn.disabled = true;
      btn.textContent = "Saving…";
    }

    // Floor coords so quackapi integer-ish path is safe; DOUBLE cast also accepts floats.
    const qs = new URLSearchParams({
      page: String(Math.floor(Number(row.page))),
      x0: String(Number(row.x0)),
      y0: String(Number(row.y0)),
      x1: String(Number(row.x1)),
      y1: String(Number(row.y1)),
      text: String(row.text || ""),
      kind: String(row.kind || "MANUAL"),
      scope: "one",
      actor: actor,
      reason: "missed by AI · remainder scan"
    });
    const url = "/api/documents/" + docId + "/add?" + qs.toString();

    try {
      // quackapi POST routes require a JSON body (empty object) — bare POST → 400.
      const r = await fetchJson(url, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: "{}"
      });
      if (!r.ok) {
        toast("Add failed · HTTP " + r.status + " · " + String(r.raw || "").slice(0, 180), true);
        if (btn) {
          btn.disabled = false;
          btn.textContent = "Add as redaction";
        }
        return;
      }
      addedIds.add(id);
      toast('Added as accepted redaction · "' + (row.text || "") + '"');
      renderList();
      // Nudge review queue if present
      if (typeof window.__reviewReload === "function") {
        try {
          window.__reviewReload();
        } catch (_) {}
      }
    } catch (err) {
      toast("Add failed · " + (err && err.message ? err.message : String(err)), true);
      if (btn) {
        btn.disabled = false;
        btn.textContent = "Add as redaction";
      }
    } finally {
      inflight.delete(id);
    }
  }

  async function load() {
    ensurePanel();
    const url = apiUrl();
    const list = document.getElementById("rm-list");
    if (!url) {
      if (list)
        list.innerHTML =
          '<div class="rm-empty">No document/case context — open a review page or /ui/missed?doc=ID.</div>';
      return;
    }
    try {
      const r = await fetchJson(url);
      if (!r.ok) {
        if (list)
          list.innerHTML =
            '<div class="rm-empty">Remainder API HTTP ' +
            r.status +
            (standalone ? "" : " — is remainder_scan wired into boot?") +
            "</div>";
        return;
      }
      items = normalizeRows(r.data).map(function (row) {
        // Prefer this document when case-level payload is mixed.
        return row;
      });
      if (docId > 0) {
        items = items.filter(function (row) {
          return Number(row.document_id) === docId || row.document_id == null;
        });
      }
      renderList();
    } catch (err) {
      if (list)
        list.innerHTML =
          '<div class="rm-empty">Failed to load remainder scan: ' +
          escapeHtml(err && err.message ? err.message : String(err)) +
          "</div>";
    }
  }

  function init() {
    if (!standalone && !docId && !caseId) return;
    ensureStyles();
    ensurePanel();
    void load();
  }

  window.__remainder = {
    reload: load,
    addAsRedaction: addAsRedaction,
    items: function () {
      return items.slice();
    }
  };

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", init);
  } else {
    init();
  }
})();
