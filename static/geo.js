/**
 * Closure — address minimap (schematic dots, not real geography).
 *
 * GET /api/cases/:id/addresses → unit-square map_x/map_y
 * Click dot → filter entity list + show review link for that address’s suggestions.
 */
(function () {
  "use strict";

  const W = 320;
  const H = 200;
  const PAD_X = 24;
  const PAD_Y = 22;
  const INNER_W = W - PAD_X * 2;
  const INNER_H = H - PAD_Y * 2;

  const C = window.Closure;
  const esc = C.escapeHtml;

  function bootCaseId(root) {
    return C.bootCaseId({ prefer: "dataset", root: root });
  }

  function toSvg(x, y) {
    const px = PAD_X + Number(x) * INNER_W;
    const py = PAD_Y + Number(y) * INNER_H;
    return { x: px, y: py };
  }

  function radiusFor(count) {
    const n = Number(count) || 0;
    if (n >= 80) return 8;
    if (n >= 20) return 6.5;
    if (n >= 5) return 5.5;
    return 4.5;
  }

  const root = document.getElementById("geo-minimap");
  if (!root) return;

  const caseId = bootCaseId(root);
  root.dataset.caseId = String(caseId);

  const els = {
    svg: document.getElementById("geo-svg"),
    dots: document.getElementById("geo-dots"),
    halos: document.getElementById("geo-halos"),
    labels: document.getElementById("geo-city-labels"),
    count: document.getElementById("geo-count"),
    empty: document.getElementById("geo-empty"),
    err: document.getElementById("geo-err"),
    filter: document.getElementById("geo-filter"),
    filterLabel: document.getElementById("geo-filter-label"),
    filterMeta: document.getElementById("geo-filter-meta"),
    filterReview: document.getElementById("geo-filter-review"),
    filterClear: document.getElementById("geo-filter-clear"),
  };

  /** @type {Array} */
  let points = [];
  /** @type {string|null} */
  let activeEntityId = null;

  function showErr(msg) {
    if (!els.err) return;
    if (!msg) {
      els.err.hidden = true;
      els.err.textContent = "";
      return;
    }
    els.err.hidden = false;
    els.err.textContent = msg;
  }

  function paintCityLabels(rows) {
    if (!els.labels) return;
    const seen = new Map();
    rows.forEach((r) => {
      const city = String(r.city || "Unknown");
      if (seen.has(city)) return;
      // Use first point of that city as label anchor (slightly above).
      const pt = toSvg(r.map_x, r.map_y);
      seen.set(city, pt);
    });
    let html = "";
    seen.forEach((pt, city) => {
      html +=
        '<text class="geo-city-label" x="' +
        pt.x.toFixed(1) +
        '" y="' +
        Math.max(12, pt.y - 12).toFixed(1) +
        '" text-anchor="middle">' +
        esc(city) +
        "</text>";
    });
    els.labels.innerHTML = html;
  }

  function paintDots() {
    if (!els.dots || !els.halos) return;
    let dotsHtml = "";
    let haloHtml = "";
    points.forEach((r) => {
      const pt = toSvg(r.map_x, r.map_y);
      const r0 = radiusFor(r.suggestion_count);
      const isStreet = !!r.is_street_fp;
      const eid = String(r.entity_id);
      const on = activeEntityId != null && eid === activeEntityId;
      const dim = activeEntityId != null && eid !== activeEntityId;
      const cls =
        "geo-dot " +
        (isStreet ? "street" : "addr") +
        (on ? " on" : "") +
        (dim ? " dim" : "");
      const title =
        String(r.canonical_text || "") +
        " · " +
        (r.suggestion_count || 0) +
        " suggestions" +
        (r.city ? " · " + r.city : "");
      dotsHtml +=
        '<circle class="' +
        cls +
        '" data-entity-id="' +
        esc(String(eid)) +
        '" cx="' +
        pt.x.toFixed(2) +
        '" cy="' +
        pt.y.toFixed(2) +
        '" r="' +
        (on ? r0 + 1.2 : r0) +
        '" tabindex="0" role="button" aria-label="' +
        esc(title) +
        '">' +
        "<title>" +
        esc(title) +
        "</title></circle>";
      haloHtml +=
        '<circle class="geo-halo' +
        (on ? " on" : "") +
        '" data-entity-id="' +
        esc(String(eid)) +
        '" cx="' +
        pt.x.toFixed(2) +
        '" cy="' +
        pt.y.toFixed(2) +
        '" r="' +
        (r0 + 5) +
        '"></circle>';
    });
    els.halos.innerHTML = haloHtml;
    els.dots.innerHTML = dotsHtml;

    els.dots.querySelectorAll(".geo-dot").forEach((el) => {
      const activate = (ev) => {
        if (ev) {
          ev.preventDefault();
          ev.stopPropagation();
        }
        const eid = el.getAttribute("data-entity-id");
        if (!eid) return;
        if (activeEntityId === eid) {
          clearFilter();
        } else {
          filterEntity(eid);
        }
      };
      el.addEventListener("click", activate);
      el.addEventListener("keydown", (ev) => {
        if (ev.key === "Enter" || ev.key === " ") activate(ev);
      });
    });
  }

  function applyEntityListFilter(entityId) {
    const card = document.getElementById("ents-card");
    if (!card) return;
    const ents = card.querySelectorAll(".ent[data-entity-id]");
    if (entityId == null) {
      card.classList.remove("geo-filtering");
      ents.forEach((el) => {
        el.classList.remove("geo-hit", "geo-dim");
      });
      return;
    }
    card.classList.add("geo-filtering");
    let hitEl = null;
    ents.forEach((el) => {
      const eid = String(el.dataset.entityId || "");
      const hit = eid === String(entityId);
      el.classList.toggle("geo-hit", hit);
      el.classList.toggle("geo-dim", !hit);
      if (hit) hitEl = el;
    });
    if (hitEl && typeof hitEl.scrollIntoView === "function") {
      hitEl.scrollIntoView({ block: "nearest", behavior: "smooth" });
    }
  }

  function filterEntity(entityId) {
    const eid = String(entityId);
    const row = points.find((p) => String(p.entity_id) === eid);
    if (!row) return;
    activeEntityId = eid;
    paintDots();
    applyEntityListFilter(activeEntityId);

    if (els.filter) {
      els.filter.classList.add("on");
      if (els.filterLabel) els.filterLabel.textContent = row.canonical_text || "—";
      if (els.filterMeta) {
        const parts = [
          row.kind || "",
          (row.suggestion_count || 0) + " suggestions",
          (row.pending_count || 0) + " pending",
        ];
        if (row.city) parts.push(row.city + (row.state ? ", " + row.state : ""));
        els.filterMeta.textContent = parts.filter(Boolean).join(" · ");
      }
      if (els.filterReview) {
        els.filterReview.href =
          "/ui/bulk?entity=" +
          encodeURIComponent(String(activeEntityId)) +
          "&case=" +
          encodeURIComponent(String(caseId));
      }
    }

    try {
      window.dispatchEvent(
        new CustomEvent("geo:filter", {
          detail: {
            caseId: caseId,
            entityId: activeEntityId,
            point: row,
          },
        })
      );
    } catch (_) {
      /* */
    }
  }

  function clearFilter() {
    activeEntityId = null;
    paintDots();
    applyEntityListFilter(null);
    if (els.filter) els.filter.classList.remove("on");
    try {
      window.dispatchEvent(
        new CustomEvent("geo:filter", {
          detail: { caseId: caseId, entityId: null, point: null },
        })
      );
    } catch (_) {
      /* */
    }
  }

  async function load() {
    showErr("");
    if (els.empty) els.empty.hidden = true;
    try {
      const res = await fetch(
        "/api/cases/" + encodeURIComponent(String(caseId)) + "/addresses",
        { headers: { Accept: "application/json" } }
      );
      const text = await res.text();
      let rows;
      try {
        rows = JSON.parse(text);
      } catch (_) {
        throw new Error("non-JSON " + res.status);
      }
      if (!Array.isArray(rows)) rows = rows ? [rows] : [];
      points = rows.map((r) => ({
        entity_id: r.entity_id != null ? String(r.entity_id) : "",
        case_id: r.case_id != null ? String(r.case_id) : "",
        kind: r.kind,
        canonical_text: r.canonical_text,
        city: r.city,
        state: r.state,
        zip: r.zip,
        is_street_fp: !!(r.is_street_fp === true || r.is_street_fp === "true" || r.is_street_fp === 1),
        map_x: Number(r.map_x),
        map_y: Number(r.map_y),
        suggestion_count: Number(r.suggestion_count) || 0,
        pending_count: Number(r.pending_count) || 0,
        accepted_count: Number(r.accepted_count) || 0,
        rejected_count: Number(r.rejected_count) || 0,
        first_document_id:
          r.first_document_id != null ? String(r.first_document_id) : r.first_document_id,
        first_page_no: r.first_page_no,
        is_schematic: true,
      }));

      if (els.count) {
        els.count.textContent =
          points.length + (points.length === 1 ? " address" : " addresses");
      }

      if (points.length === 0) {
        if (els.empty) els.empty.hidden = false;
        if (els.dots) els.dots.innerHTML = "";
        if (els.halos) els.halos.innerHTML = "";
        if (els.labels) els.labels.innerHTML = "";
        return;
      }

      paintCityLabels(points);
      paintDots();
    } catch (e) {
      showErr("Minimap failed to load: " + (e && e.message ? e.message : String(e)));
      if (els.count) els.count.textContent = "error";
    }
  }

  if (els.filterClear) {
    els.filterClear.addEventListener("click", (ev) => {
      ev.preventDefault();
      clearFilter();
    });
  }

  // Public API for other dashboard scripts / tests
  window.__geoMinimap = {
    caseId: caseId,
    reload: load,
    filterEntity: filterEntity,
    clearFilter: clearFilter,
    getPoints: function () {
      return points.slice();
    },
    getActiveEntityId: function () {
      return activeEntityId;
    },
  };

  void load();
})();
