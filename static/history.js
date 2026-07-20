/**
 * Closure — version history + server-side undo (Ctrl/Cmd+Z, u).
 * Routes: GET /api/cases/:id/history, POST /api/undo, POST /api/cases/:id/restore
 */
(function () {
  "use strict";

  const ACTOR = "A. Subbarao";

  function bootCaseId() {
    try {
      const boot = JSON.parse(document.getElementById("boot-data").textContent);
      if (boot && boot.caseId != null && String(boot.caseId).trim() !== "")
        return String(boot.caseId);
    } catch (_) {
      /* fall through */
    }
    const body = document.body;
    if (body && body.dataset && body.dataset.caseId) {
      const s = String(body.dataset.caseId).trim();
      if (s) return s;
    }
    const el = document.querySelector("[data-case-id]");
    if (el) {
      const s = String(el.getAttribute("data-case-id") || "").trim();
      if (s) return s;
    }
    // case id is an opaque natural-key string (e.g. "24-001001")
    const m = /^\/cases\/([^/]+)/.exec(window.location.pathname || "");
    if (m) return decodeURIComponent(m[1]);
    return "1";
  }

  function bootActor() {
    try {
      const boot = JSON.parse(document.getElementById("boot-data").textContent);
      if (boot && boot.actor) return String(boot.actor);
    } catch (_) {
      /* */
    }
    return ACTOR;
  }

  const caseId = bootCaseId();
  const actor = bootActor();

  const els = {
    fab: document.getElementById("hist-fab"),
    drawer: document.getElementById("hist-drawer"),
    scrim: document.getElementById("hist-scrim"),
    close: document.getElementById("hist-close"),
    list: document.getElementById("hist-list"),
    undoBtn: document.getElementById("hist-undo-btn"),
    refresh: document.getElementById("hist-refresh"),
    toast: document.getElementById("hist-toast"),
  };

  if (!els.drawer || !els.list) return;

  let open = false;
  let busy = false;
  let toastTimer = null;
  /** @type {Array} */
  let batches = [];

  function toast(msg) {
    if (!els.toast) return;
    els.toast.textContent = msg;
    els.toast.classList.add("show");
    if (toastTimer) clearTimeout(toastTimer);
    toastTimer = setTimeout(() => els.toast.classList.remove("show"), 4200);
  }

  function setOpen(v) {
    open = !!v;
    els.drawer.classList.toggle("open", open);
    els.drawer.setAttribute("aria-hidden", open ? "false" : "true");
    if (els.scrim) {
      els.scrim.hidden = !open;
      els.scrim.classList.toggle("open", open);
    }
    document.body.classList.toggle("hist-open", open);
    if (open) void loadHistory();
  }

  function escapeHtml(s) {
    return String(s == null ? "" : s)
      .replace(/&/g, "&amp;")
      .replace(/</g, "&lt;")
      .replace(/>/g, "&gt;")
      .replace(/"/g, "&quot;");
  }

  function fmtTs(ts) {
    if (!ts) return "";
    try {
      const d = new Date(ts);
      if (isNaN(d.getTime())) return String(ts).slice(0, 19);
      return d.toLocaleString(undefined, {
        month: "short",
        day: "numeric",
        hour: "2-digit",
        minute: "2-digit",
        second: "2-digit",
      });
    } catch (_) {
      return String(ts).slice(0, 19);
    }
  }

  function render() {
    if (!batches.length) {
      els.list.innerHTML =
        '<div class="hist-empty">No version history yet.<br>Accept or reject a suggestion to start the timeline.</div>';
      return;
    }
    const html = batches
      .map((b, idx) => {
        const undone = b.undone === true || b.undone === "true" || b.undone === 1;
        const isUndo = b.is_undo === true || b.is_undo === "true" || b.is_undo === 1;
        const chips = [];
        const n = Number(b.decision_count) || 0;
        chips.push('<span class="chip">' + n + " change" + (n === 1 ? "" : "s") + "</span>");
        if (Number(b.accepted_count) > 0)
          chips.push('<span class="chip ok">' + b.accepted_count + " acc</span>");
        if (Number(b.rejected_count) > 0)
          chips.push('<span class="chip rej">' + b.rejected_count + " rej</span>");
        if (Number(b.pending_count) > 0)
          chips.push('<span class="chip pend">' + b.pending_count + " pend</span>");
        if (isUndo) chips.push('<span class="chip undo">undo</span>');
        if (undone) chips.push('<span class="chip">undone</span>');

        // Restore available for non-undone forward batches that aren't the tip-only noop.
        const canRestore = !undone && !isUndo && idx > 0;
        const actions = canRestore
          ? '<div class="actions"><button type="button" data-restore="' +
            escapeHtml(b.batch_id) +
            '">Restore to here</button></div>'
          : "";

        return (
          '<div class="hist-item' +
          (undone ? " undone" : "") +
          (isUndo ? " is-undo" : "") +
          '" data-batch="' +
          escapeHtml(b.batch_id) +
          '">' +
          '<div class="lbl">' +
          escapeHtml(b.label || "Batch") +
          "</div>" +
          '<div class="meta"><span>' +
          escapeHtml(fmtTs(b.ts)) +
          "</span><span>" +
          escapeHtml(b.actor || "reviewer") +
          "</span></div>" +
          '<div class="counts">' +
          chips.join("") +
          "</div>" +
          actions +
          "</div>"
        );
      })
      .join("");
    els.list.innerHTML = html;
  }

  async function loadHistory() {
    try {
      const res = await fetch(
        "/api/cases/" + encodeURIComponent(String(caseId)) + "/history",
        {
          headers: { Accept: "application/json" },
        }
      );
      if (!res.ok) {
        els.list.innerHTML =
          '<div class="hist-empty">Could not load history (HTTP ' + res.status + ").</div>";
        return;
      }
      const data = await res.json();
      // quackapi may return array or {rows:[...]} or single object
      if (Array.isArray(data)) batches = data;
      else if (data && Array.isArray(data.rows)) batches = data.rows;
      else if (data && data.batch_id) batches = [data];
      else batches = [];
      render();
    } catch (err) {
      els.list.innerHTML =
        '<div class="hist-empty">History error: ' +
        escapeHtml(err && err.message ? err.message : String(err)) +
        "</div>";
    }
  }

  function reloadAfterMutation() {
    // Soft: refresh history; hard: reload page so review.js state matches server.
    void loadHistory();
    // Give COPY a beat to land, then reload review surface.
    setTimeout(() => {
      window.location.reload();
    }, 180);
  }

  async function postUndo() {
    if (busy) return;
    busy = true;
    if (els.undoBtn) els.undoBtn.disabled = true;
    try {
      // Peek label for toast
      let label = "latest batch";
      try {
        const st = await fetch(
          "/api/undo/status?case_id=" + encodeURIComponent(String(caseId)),
          {
            headers: { Accept: "application/json" },
          }
        );
        if (st.ok) {
          const j = await st.json();
          const row = Array.isArray(j) ? j[0] : j;
          if (row && row.latest_label) label = row.latest_label;
          if (row && !row.latest_batch_id && !row.latest_label) {
            toast("Nothing to undo");
            return;
          }
        }
      } catch (_) {
        /* continue */
      }

      const q = new URLSearchParams();
      q.set("actor", actor);
      q.set("case_id", String(caseId));
      const res = await fetch("/api/undo?" + q.toString(), {
        method: "POST",
        headers: { Accept: "application/json", "Content-Type": "application/json" },
        body: "{}",
      });
      if (!res.ok && res.status !== 200) {
        toast("Undo failed (HTTP " + res.status + ")");
        return;
      }
      toast('Undid: "' + label + '"');
      reloadAfterMutation();
    } catch (err) {
      toast("Undo failed: " + (err && err.message ? err.message : String(err)));
    } finally {
      busy = false;
      if (els.undoBtn) els.undoBtn.disabled = false;
    }
  }

  async function postRestore(batchId) {
    if (busy || !batchId) return;
    busy = true;
    try {
      const q = new URLSearchParams();
      q.set("batch_id", batchId);
      q.set("actor", actor);
      const res = await fetch(
        "/api/cases/" + encodeURIComponent(String(caseId)) + "/restore?" + q.toString(),
        {
          method: "POST",
          headers: { Accept: "application/json", "Content-Type": "application/json" },
          body: "{}",
        }
      );
      if (!res.ok && res.status !== 200) {
        toast("Restore failed (HTTP " + res.status + ")");
        return;
      }
      const b = batches.find((x) => x.batch_id === batchId);
      toast('Restored to: "' + (b && b.label ? b.label : "checkpoint") + '"');
      reloadAfterMutation();
    } catch (err) {
      toast("Restore failed: " + (err && err.message ? err.message : String(err)));
    } finally {
      busy = false;
    }
  }

  // Capture-phase keyboard: own 'u' and Cmd/Ctrl+Z over review.js client undo.
  function onKey(e) {
    const tag = (e.target && e.target.tagName) || "";
    if (tag === "INPUT" || tag === "TEXTAREA" || tag === "SELECT" || e.target.isContentEditable)
      return;

    if (e.key === "h" || e.key === "H") {
      if (e.metaKey || e.ctrlKey || e.altKey) return;
      e.preventDefault();
      e.stopPropagation();
      setOpen(!open);
      return;
    }

    if (e.key === "Escape" && open) {
      e.preventDefault();
      e.stopPropagation();
      setOpen(false);
      return;
    }

    const isUndoKey =
      e.key === "u" ||
      e.key === "U" ||
      ((e.metaKey || e.ctrlKey) && (e.key === "z" || e.key === "Z") && !e.shiftKey);

    if (isUndoKey) {
      e.preventDefault();
      e.stopImmediatePropagation();
      void postUndo();
    }
  }

  if (els.fab) els.fab.addEventListener("click", () => setOpen(true));
  if (els.close) els.close.addEventListener("click", () => setOpen(false));
  if (els.scrim) els.scrim.addEventListener("click", () => setOpen(false));
  if (els.undoBtn) els.undoBtn.addEventListener("click", () => void postUndo());
  if (els.refresh) els.refresh.addEventListener("click", () => void loadHistory());
  els.list.addEventListener("click", (e) => {
    const btn = e.target && e.target.closest ? e.target.closest("[data-restore]") : null;
    if (!btn) return;
    const id = btn.getAttribute("data-restore");
    if (id && window.confirm("Restore to this version? Later changes will be inverted (append-only).")) {
      void postRestore(id);
    }
  });

  document.addEventListener("keydown", onKey, true);

  window.__history = {
    open: () => setOpen(true),
    close: () => setOpen(false),
    undo: () => postUndo(),
    reload: () => loadHistory(),
    caseId: () => caseId,
  };
})();
