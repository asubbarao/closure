/**
 * Progressive enhancement only. State lives in SQL + SSR.
 * Clicks: [data-action]. Review keys: j/k a/r A/R H e n u [ ]
 */
(function () {
  "use strict";
  var body = document.body;
  var actor = (body && body.dataset.actor) || "reviewer";

  function q(s, r) { return (r || document).querySelector(s); }
  function qa(s, r) {
    return Array.prototype.slice.call((r || document).querySelectorAll(s));
  }
  function typing(el) {
    return el && el.tagName && /INPUT|TEXTAREA|SELECT/i.test(el.tagName);
  }
  function post(url) {
    return fetch(url, {
      method: "POST",
      headers: { Accept: "application/json", "Content-Type": "application/json" },
      body: "{}",
    }).then(function (r) {
      if (!r.ok) throw new Error("HTTP " + r.status + " " + url);
      return r;
    });
  }
  function go(url) {
    return post(url).then(function () { location.reload(); }).catch(function (e) {
      console.error(e);
      alert(e.message || String(e));
    });
  }
  function qs(o) {
    var p = new URLSearchParams();
    Object.keys(o).forEach(function (k) {
      if (o[k] != null && o[k] !== "") p.set(k, String(o[k]));
    });
    return p.toString();
  }

  /* Product API — keep in sync with server/routes.sql */
  var api = {
    decide: function (id, status) {
      return "/api/suggestions/" + encodeURIComponent(id) + "/decision?" +
        qs({ status: status, actor: actor });
    },
    entity: function (id, status) {
      return "/api/entities/" + encodeURIComponent(id) + "/decision?" +
        qs({ status: status, actor: actor });
    },
    band: function (docId, band, status) {
      return "/api/documents/" + encodeURIComponent(docId) + "/bands/" +
        encodeURIComponent(band) + "/decision?" + qs({ status: status, actor: actor });
    },
    acceptHigh: function (caseId) {
      return "/api/cases/" + encodeURIComponent(caseId) +
        "/accept-high?" + qs({ threshold: 90, actor: actor });
    },
    undo: function (caseId) {
      return "/api/cases/" + encodeURIComponent(caseId) + "/undo?" +
        qs({ actor: actor });
    },
    export: function (caseId) {
      return "/api/cases/" + encodeURIComponent(caseId) + "/export";
    },
    mark: function (docId, q) {
      return "/api/documents/" + encodeURIComponent(docId) + "/marks?" + qs(q);
    },
    flaggedBulk: function (caseId, status) {
      return "/api/cases/" + encodeURIComponent(caseId) + "/flagged/decision?" +
        qs({ status: status, actor: actor });
    },
    docFlaggedBulk: function (docId, status) {
      return "/api/documents/" + encodeURIComponent(docId) + "/flagged/decision?" +
        qs({ status: status, actor: actor });
    },
  };

  function runAction(el) {
    var a = el.getAttribute("data-action");
    if (!a) return;
    var caseId = el.getAttribute("data-case-id") || body.dataset.caseId || "";
    var docId = el.getAttribute("data-doc-id") || body.dataset.docId || "";
    if (a === "decide") {
      var st = el.getAttribute("data-status");
      var why = el.getAttribute("data-reason") || "";
      var url = api.decide(el.getAttribute("data-id"), st);
      if (why) url += "&reason=" + encodeURIComponent(why);
      go(url);
    } else if (a === "entity") {
      go(api.entity(el.getAttribute("data-entity-id"), el.getAttribute("data-status")));
    } else if (a === "band") {
      var band = el.getAttribute("data-band");
      if (band && band !== "flagged")
        go(api.band(docId, band, el.getAttribute("data-status") || "accepted"));
    } else if (a === "accept-high") {
      go(api.acceptHigh(caseId));
    } else if (a === "flagged-bulk") {
      go(api.flaggedBulk(caseId, el.getAttribute("data-status") || "rejected"));
    } else if (a === "doc-flagged-bulk") {
      go(api.docFlaggedBulk(docId, el.getAttribute("data-status") || "rejected"));
    } else if (a === "undo") {
      go(api.undo(caseId));
    } else if (a === "export") {
      if (el.disabled) return;
      go(api.export(caseId));
    }
  }

  document.addEventListener("click", function (ev) {
    var el = ev.target.closest("[data-action]");
    if (!el) return;
    ev.preventDefault();
    runAction(el);
  });

  /* ── review keyboard ─────────────────────────────────────────── */
  var focusIdx = 0;
  function pendingMarks() {
    return qa(".mark[data-status='pending']").filter(function (m) {
      return m.getAttribute("data-band") !== "flagged";
    });
  }
  function setCurrent(m) {
    qa(".mark, .sugg").forEach(function (el) { el.classList.remove("current"); });
    if (!m) return;
    m.classList.add("current");
    if (m.scrollIntoView) m.scrollIntoView({ block: "nearest", behavior: "smooth" });
    var id = m.getAttribute("data-id");
    var s = id && q(".sugg[data-id='" + id + "']");
    if (s) s.classList.add("current");
  }
  function focusMark(i) {
    var marks = pendingMarks();
    if (!marks.length) return;
    focusIdx = ((i % marks.length) + marks.length) % marks.length;
    setCurrent(marks[focusIdx]);
  }
  function curMark() {
    return q(".mark.current") || pendingMarks()[0] || null;
  }

  if (body && body.dataset.surface === "review") {
    qa(".mark").forEach(function (m) {
      m.addEventListener("click", function () {
        var marks = pendingMarks();
        var i = marks.indexOf(m);
        focusIdx = i >= 0 ? i : 0;
        setCurrent(m);
      });
    });
    document.addEventListener("keydown", function (e) {
      if (typing(e.target)) return;
      var k = e.key;
      var caseId = body.dataset.caseId || "";
      var docId = body.dataset.docId || "";
      var pageNo = +body.dataset.pageNo || 1;
      var pageCount = +body.dataset.pageCount || 1;
      var m = curMark();
      if (k === "j" || k === "ArrowDown") { e.preventDefault(); focusMark(focusIdx + 1); }
      else if (k === "k" || k === "ArrowUp") { e.preventDefault(); focusMark(focusIdx - 1); }
      else if (k === "a" && !e.shiftKey && m) {
        e.preventDefault();
        go(api.decide(m.getAttribute("data-id"), "accepted"));
      } else if (k === "r" && !e.shiftKey && m) {
        e.preventDefault();
        go(api.decide(m.getAttribute("data-id"), "rejected"));
      } else if (k === "A" || (k === "a" && e.shiftKey)) {
        e.preventDefault();
        go(api.band(docId, "high", "accepted"));
      } else if (k === "R" || (k === "r" && e.shiftKey)) {
        e.preventDefault();
        go(api.band(docId, "review", "rejected"));
      } else if (k === "H" || (k === "h" && e.shiftKey)) {
        e.preventDefault();
        go(api.acceptHigh(caseId));
      } else if ((k === "e" || k === "E") && m && m.getAttribute("data-entity-id")) {
        e.preventDefault();
        go(api.entity(m.getAttribute("data-entity-id"), "accepted"));
      } else if (k === "u" && !e.metaKey && !e.ctrlKey) {
        e.preventDefault();
        go(api.undo(caseId));
      } else if (k === "n" || k === "N") {
        e.preventDefault();
        body.classList.toggle("add-mode");
      } else if (k === "[" && pageNo > 1) {
        e.preventDefault();
        location.href = "/documents/" + encodeURIComponent(docId) + "/pages/" + (pageNo - 1);
      } else if (k === "]" && pageNo < pageCount) {
        e.preventDefault();
        location.href = "/documents/" + encodeURIComponent(docId) + "/pages/" + (pageNo + 1);
      }
    });
    focusMark(0);
    bootAdd(body.dataset.docId || "");
  }

  if (body && (body.dataset.surface === "case" || body.dataset.surface === "stream" ||
               body.dataset.surface === "flagged")) {
    document.addEventListener("keydown", function (e) {
      if (typing(e.target)) return;
      var caseId = body.dataset.caseId || "";
      if (e.key === "H" || (e.key === "h" && e.shiftKey)) {
        e.preventDefault();
        go(api.acceptHigh(caseId));
      } else if (e.key === "u" && !e.metaKey && !e.ctrlKey) {
        e.preventDefault();
        go(api.undo(caseId));
      } else if (e.key === "F" || (e.key === "f" && e.shiftKey)) {
        e.preventDefault();
        if (caseId) location.href = "/cases/" + encodeURIComponent(caseId) + "/flagged";
      }
    });
  }

  function bootAdd(docId) {
    var page = q(".pdf-page");
    if (!page || !docId) return;
    var scale = +body.dataset.scale || 1;
    var pageNo = +body.dataset.pageNo || 1;
    var start = null, box = null;
    function pt(ev) {
      var r = page.getBoundingClientRect();
      return { x: (ev.clientX - r.left) / scale, y: (ev.clientY - r.top) / scale };
    }
    page.addEventListener("mousedown", function (ev) {
      if (ev.button !== 0 || (!ev.shiftKey && !body.classList.contains("add-mode"))) return;
      ev.preventDefault();
      start = pt(ev);
      if (!box) {
        box = document.createElement("div");
        box.className = "add-box";
        box.style.cssText = "position:absolute;border:2px dashed #1d4ed8;background:rgba(29,78,216,.12)";
        page.appendChild(box);
      }
    });
    window.addEventListener("mousemove", function (ev) {
      if (!start || !box) return;
      var p = pt(ev);
      var x0 = Math.min(start.x, p.x), y0 = Math.min(start.y, p.y);
      var x1 = Math.max(start.x, p.x), y1 = Math.max(start.y, p.y);
      box.style.left = x0 * scale + "px";
      box.style.top = y0 * scale + "px";
      box.style.width = (x1 - x0) * scale + "px";
      box.style.height = (y1 - y0) * scale + "px";
      box.dataset.x0 = x0; box.dataset.y0 = y0; box.dataset.x1 = x1; box.dataset.y1 = y1;
    });
    window.addEventListener("mouseup", function () {
      if (!start || !box) return;
      start = null;
      var x0 = +box.dataset.x0, y0 = +box.dataset.y0, x1 = +box.dataset.x1, y1 = +box.dataset.y1;
      if (Math.abs(x1 - x0) < 2 || Math.abs(y1 - y0) < 2) return;
      var text = window.prompt("Text for missed redaction", "") || "MANUAL";
      go(api.mark(docId, {
        page: pageNo, x0: x0, y0: y0, x1: x1, y1: y1, text: text, actor: actor
      }));
    });
  }
})();
