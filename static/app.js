/**
 * Closure thin client — progressive enhancement only.
 * Product state is SSR (tera) + SQL. After any mutation: reload.
 * Browser-only: keyboard focus, mark click, drag-add, POST helpers.
 */
(function () {
  "use strict";

  var actor =
    (document.body && document.body.dataset.actor) ||
    "reviewer";

  function qs(sel, root) {
    return (root || document).querySelector(sel);
  }
  function qsa(sel, root) {
    return Array.prototype.slice.call((root || document).querySelectorAll(sel));
  }

  function post(url) {
    return fetch(url, {
      method: "POST",
      headers: {
        Accept: "application/json",
        "Content-Type": "application/json",
      },
      body: "{}",
    }).then(function (r) {
      if (!r.ok) throw new Error("HTTP " + r.status + " " + url);
      return r;
    });
  }

  function mutate(url) {
    return post(url)
      .then(function () {
        location.reload();
      })
      .catch(function (e) {
        console.error(e);
        alert(e.message || String(e));
      });
  }

  function decisionUrl(id, status, reason) {
    var q = new URLSearchParams();
    q.set("status", status);
    q.set("actor", actor);
    if (reason) q.set("reason", reason);
    return "/api/suggestions/" + encodeURIComponent(id) + "/decision?" + q.toString();
  }

  function entityUrl(id, status) {
    var q = new URLSearchParams();
    q.set("status", status);
    q.set("actor", actor);
    return "/api/entities/" + encodeURIComponent(id) + "/decision?" + q.toString();
  }

  /* ── case library ─────────────────────────────────────────────── */
  function bootCase() {
    var caseId = document.body && document.body.dataset.caseId;
    if (!caseId) return;

    qsa("[data-entity-decision]").forEach(function (el) {
      el.addEventListener("click", function (ev) {
        ev.preventDefault();
        var id = el.getAttribute("data-entity-id");
        var status = el.getAttribute("data-entity-decision");
        if (id && status) mutate(entityUrl(id, status));
      });
    });

    var acceptHigh = qs("#btn-accept-high-case");
    if (acceptHigh) {
      acceptHigh.addEventListener("click", function () {
        mutate(
          "/api/cases/" +
            encodeURIComponent(caseId) +
            "/accept-high?threshold=90&actor=" +
            encodeURIComponent(actor)
        );
      });
    }

    var exportBtn = qs("#export-btn");
    if (exportBtn) {
      exportBtn.addEventListener("click", function () {
        mutate(
          "/api/cases/" + encodeURIComponent(caseId) + "/export"
        );
      });
    }

    var undoBtn = qs("#btn-undo");
    if (undoBtn) {
      undoBtn.addEventListener("click", function () {
        mutate(
          "/api/undo?case_id=" +
            encodeURIComponent(caseId) +
            "&actor=" +
            encodeURIComponent(actor)
        );
      });
    }
  }

  /* ── review workspace ─────────────────────────────────────────── */
  var focusIdx = 0;

  function pendingMarks() {
    return qsa(".mark[data-status='pending'], .mark.pending");
  }

  function focusMark(i) {
    var marks = pendingMarks();
    if (!marks.length) return;
    focusIdx = ((i % marks.length) + marks.length) % marks.length;
    marks.forEach(function (m, j) {
      m.classList.toggle("current", j === focusIdx);
    });
    var m = marks[focusIdx];
    if (m && m.scrollIntoView) m.scrollIntoView({ block: "nearest", behavior: "smooth" });
  }

  function currentId() {
    var marks = pendingMarks();
    var m = marks[focusIdx] || marks[0];
    return m && (m.dataset.id || m.getAttribute("data-id"));
  }

  function decide(status) {
    var id = currentId();
    if (!id) return;
    mutate(decisionUrl(id, status));
  }

  function bootReview() {
    var docId = document.body && document.body.dataset.docId;
    if (!docId) return;

    qsa(".mark").forEach(function (m) {
      m.addEventListener("click", function () {
        var id = m.dataset.id || m.getAttribute("data-id");
        if (!id) return;
        qsa(".mark").forEach(function (x) {
          x.classList.remove("current");
        });
        m.classList.add("current");
        var marks = pendingMarks();
        focusIdx = Math.max(0, marks.indexOf(m));
      });
    });

    qsa("[data-decide]").forEach(function (btn) {
      btn.addEventListener("click", function (ev) {
        ev.preventDefault();
        var id = btn.getAttribute("data-id") || currentId();
        var status = btn.getAttribute("data-decide");
        if (id && status) mutate(decisionUrl(id, status));
      });
    });

    qsa("[data-band-decide]").forEach(function (btn) {
      btn.addEventListener("click", function (ev) {
        ev.preventDefault();
        var band = btn.getAttribute("data-band-decide");
        var status = btn.getAttribute("data-status") || "accepted";
        if (!band) return;
        mutate(
          "/api/documents/" +
            encodeURIComponent(docId) +
            "/band/" +
            encodeURIComponent(band) +
            "/decision?status=" +
            encodeURIComponent(status) +
            "&actor=" +
            encodeURIComponent(actor)
        );
      });
    });

    document.addEventListener("keydown", function (e) {
      if (e.target && /input|textarea|select/i.test(e.target.tagName)) return;
      var k = e.key;
      if (k === "j" || k === "ArrowDown") {
        e.preventDefault();
        focusMark(focusIdx + 1);
      } else if (k === "k" || k === "ArrowUp") {
        e.preventDefault();
        focusMark(focusIdx - 1);
      } else if (k === "a") {
        e.preventDefault();
        decide("accepted");
      } else if (k === "r") {
        e.preventDefault();
        decide("rejected");
      } else if (k === "u") {
        e.preventDefault();
        var caseId = document.body.dataset.caseId || "";
        mutate(
          "/api/undo?case_id=" +
            encodeURIComponent(caseId) +
            "&actor=" +
            encodeURIComponent(actor)
        );
      }
    });

    focusMark(0);
    bootAddMissed(docId);
  }

  /* ── add-missed drag (only irreducible canvas work) ───────────── */
  function bootAddMissed(docId) {
    var page = qs(".pdf-page") || qs("#pdf-page");
    if (!page) return;
    var scale = parseFloat(document.body.dataset.scale || "1") || 1;
    var pageNo = parseInt(document.body.dataset.pageNo || "1", 10) || 1;
    var start = null;
    var box = null;

    function pt(ev) {
      var r = page.getBoundingClientRect();
      return {
        x: (ev.clientX - r.left) / scale,
        y: (ev.clientY - r.top) / scale,
      };
    }

    page.addEventListener("mousedown", function (ev) {
      if (ev.button !== 0 || !ev.altKey && !ev.shiftKey && !document.body.classList.contains("add-mode"))
        return;
      ev.preventDefault();
      start = pt(ev);
      if (!box) {
        box = document.createElement("div");
        box.className = "add-box";
        box.style.position = "absolute";
        box.style.border = "2px dashed #1d4ed8";
        box.style.background = "rgba(29,78,216,.12)";
        page.style.position = page.style.position || "relative";
        page.appendChild(box);
      }
    });

    window.addEventListener("mousemove", function (ev) {
      if (!start || !box) return;
      var p = pt(ev);
      var x0 = Math.min(start.x, p.x);
      var y0 = Math.min(start.y, p.y);
      var x1 = Math.max(start.x, p.x);
      var y1 = Math.max(start.y, p.y);
      box.style.left = x0 * scale + "px";
      box.style.top = y0 * scale + "px";
      box.style.width = (x1 - x0) * scale + "px";
      box.style.height = (y1 - y0) * scale + "px";
      box.dataset.x0 = x0;
      box.dataset.y0 = y0;
      box.dataset.x1 = x1;
      box.dataset.y1 = y1;
    });

    window.addEventListener("mouseup", function () {
      if (!start || !box) return;
      start = null;
      var x0 = parseFloat(box.dataset.x0 || "0");
      var y0 = parseFloat(box.dataset.y0 || "0");
      var x1 = parseFloat(box.dataset.x1 || "0");
      var y1 = parseFloat(box.dataset.y1 || "0");
      if (Math.abs(x1 - x0) < 2 || Math.abs(y1 - y0) < 2) return;
      var text = window.prompt("Text for missed redaction", "") || "MANUAL";
      var q = new URLSearchParams();
      q.set("page", String(pageNo));
      q.set("x0", String(x0));
      q.set("y0", String(y0));
      q.set("x1", String(x1));
      q.set("y1", String(y1));
      q.set("text", text);
      q.set("actor", actor);
      mutate(
        "/api/documents/" + encodeURIComponent(docId) + "/add?" + q.toString()
      );
    });

    document.addEventListener("keydown", function (e) {
      if (e.key === "n" && !/input|textarea/i.test((e.target || {}).tagName || "")) {
        document.body.classList.toggle("add-mode");
      }
    });
  }

  document.addEventListener("DOMContentLoaded", function () {
    bootCase();
    bootReview();
  });
})();
