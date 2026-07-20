/**
 * Closure — judge ensemble confidence surface
 * Fetches GET /api/suggestions/:id/judges and paints:
 *   - why-card panel for the current flagged item
 *   - compact vote chips on flagged queue rows
 *   - 60→95 confidence color gradient on scores
 * Self-mounts on the review workspace; CSS from #judge-panel-css or injected.
 */
(function () {
  "use strict";

  const CSS_ID = "judge-panel-css";
  const cache = new Map(); // suggestion_id → { panel, votes[] }
  let lastCurrentId = null;
  let observer = null;

  const FALLBACK_CSS = `
.judge-why-card{display:none;margin:0 12px 10px;border:1px solid #F3C6C0;background:#FDECEA;border-radius:8px;padding:12px 12px 10px}
.judge-why-card.on{display:block}
.judge-why-card .jwc-title{font-size:10.5px;font-weight:700;letter-spacing:.05em;text-transform:uppercase;color:#B42318;margin-bottom:6px}
.judge-why-card .jwc-head{display:flex;align-items:center;gap:8px;flex-wrap:wrap;margin-bottom:8px}
.judge-panel{display:flex;flex-direction:column;gap:4px}
.judge-vote{display:grid;grid-template-columns:56px 52px 28px 1fr;gap:6px;align-items:baseline;font-size:11px;line-height:1.35;padding:3px 0;border-top:1px solid rgba(180,35,24,.12)}
.judge-vote:first-child{border-top:none;padding-top:0}
.judge-vote .jv-name{font-weight:700;font-size:10.5px;color:#1A2230}
.judge-vote .jv-verdict{font-family:'IBM Plex Mono',ui-monospace,monospace;font-size:10px;font-weight:700;text-transform:uppercase}
.judge-vote .jv-verdict.redact{color:#087443}
.judge-vote .jv-verdict.keep{color:#B42318}
.judge-vote .jv-verdict.unsure{color:#B45309}
.judge-vote .jv-score{font-family:'IBM Plex Mono',ui-monospace,monospace;font-size:11px;font-weight:700;text-align:right}
.judge-vote .jv-reason{font-size:11px;color:#5A6577;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;min-width:0}
.judge-badge{display:inline-flex;font-family:'IBM Plex Mono',ui-monospace,monospace;font-size:10px;font-weight:700;letter-spacing:.04em;text-transform:uppercase;padding:2px 7px;border-radius:4px;border:1px solid transparent}
.judge-badge.agree{background:#E7F5EE;color:#087443;border-color:#BFE3CF}
.judge-badge.split{background:#FDF3E3;color:#B45309;border-color:#EBCB9A}
.judge-badge.conflict{background:#FDECEA;color:#B42318;border-color:#F3C6C0}
.judge-conf{font-family:'IBM Plex Mono',ui-monospace,monospace;font-size:12px;font-weight:700}
.judge-conf-label{font-size:10.5px;color:#5A6577;font-weight:500}
.sugg .judge-chips{display:flex;flex-wrap:wrap;gap:3px;margin-top:3px;align-items:center}
.sugg .judge-chip{display:inline-flex;align-items:center;gap:3px;font-family:'IBM Plex Mono',ui-monospace,monospace;font-size:9.5px;font-weight:600;padding:1px 5px;border-radius:3px;background:#F7F9FB;border:1px solid #E4E8EE;color:#5A6577}
.sugg .judge-chip .jc-v{text-transform:uppercase}
.sugg .judge-chip .jc-v.redact{color:#087443}
.sugg .judge-chip .jc-v.keep{color:#B42318}
.sugg .judge-chip .jc-v.unsure{color:#B45309}
.sugg .judge-chip .jc-s{font-weight:700}
.sugg .judge-chip-badge{font-family:'IBM Plex Mono',ui-monospace,monospace;font-size:9px;font-weight:700;text-transform:uppercase;letter-spacing:.04em;padding:1px 5px;border-radius:3px}
.sugg .judge-chip-badge.agree{background:#E7F5EE;color:#087443}
.sugg .judge-chip-badge.split{background:#FDF3E3;color:#B45309}
.sugg .judge-chip-badge.conflict{background:#FDECEA;color:#B42318}
`;

  /** Map score 60→95 onto a continuous red→amber→green ramp (not discrete bands). */
  function confGradientColor(score) {
    const n = Number(score);
    if (!isFinite(n)) return "#5A6577";
    const t = Math.max(0, Math.min(1, (n - 60) / 35));
    // 0 @60 → red (#B42318), ~0.4 → amber (#B45309), 1 @95 → green (#087443)
    const stops = [
      { t: 0, c: [180, 35, 24] },
      { t: 0.4, c: [180, 83, 9] },
      { t: 1, c: [8, 116, 67] },
    ];
    let a = stops[0],
      b = stops[stops.length - 1];
    for (let i = 0; i < stops.length - 1; i++) {
      if (t >= stops[i].t && t <= stops[i + 1].t) {
        a = stops[i];
        b = stops[i + 1];
        break;
      }
    }
    const u = (t - a.t) / Math.max(b.t - a.t, 1e-6);
    const r = Math.round(a.c[0] + (b.c[0] - a.c[0]) * u);
    const g = Math.round(a.c[1] + (b.c[1] - a.c[1]) * u);
    const bl = Math.round(a.c[2] + (b.c[2] - a.c[2]) * u);
    return "rgb(" + r + "," + g + "," + bl + ")";
  }

  function ensureCss() {
    if (document.getElementById(CSS_ID)) return;
    const style = document.createElement("style");
    style.id = CSS_ID;
    style.textContent = FALLBACK_CSS;
    document.head.appendChild(style);
  }

  function ensureWhyCard() {
    let card = document.getElementById("judge-why-card");
    if (card) return card;
    const queue = document.querySelector(".queue .q-head") || document.querySelector(".queue");
    if (!queue) return null;
    card = document.createElement("div");
    card.className = "judge-why-card";
    card.id = "judge-why-card";
    card.setAttribute("data-judge-panel", "1");
    card.hidden = true;
    card.innerHTML =
      '<div class="jwc-title">Judge panel</div>' +
      '<div class="jwc-head">' +
      '<span class="judge-badge" id="judge-badge" data-signal="">—</span>' +
      '<span class="judge-conf-label">confidence</span>' +
      '<span class="judge-conf" id="judge-conf" data-conf="0">—</span>' +
      "</div>" +
      '<div class="judge-panel" id="judge-panel" role="list" aria-label="Judge votes">' +
      voteShell("Pattern") +
      voteShell("Context") +
      voteShell("Prior") +
      "</div>";
    // Insert after band-note / bulk tools, before q-list
    const qList = document.getElementById("q-list");
    if (qList && qList.parentNode) {
      qList.parentNode.insertBefore(card, qList);
    } else {
      queue.appendChild(card);
    }
    return card;
  }

  function voteShell(name) {
    return (
      '<div class="judge-vote" data-judge="' +
      name +
      '" role="listitem">' +
      '<span class="jv-name">' +
      name +
      "</span>" +
      '<span class="jv-verdict">—</span>' +
      '<span class="jv-score">—</span>' +
      '<span class="jv-reason">—</span>' +
      "</div>"
    );
  }

  function extractRows(payload) {
    if (Array.isArray(payload)) return payload;
    if (payload && Array.isArray(payload.rows)) return payload.rows;
    if (payload && Array.isArray(payload.judges)) return payload.judges;
    if (payload && typeof payload === "object" && payload.judge_name) return [payload];
    return [];
  }

  function normalizeVotes(rows) {
    if (!rows.length) return null;
    const votes = rows
      .map((r) => ({
        judge_id: Number(r.judge_id) || 0,
        judge_name: r.judge_name || r.name || "Judge",
        factor: r.factor || "",
        verdict: String(r.verdict || "unsure").toLowerCase(),
        score: Number(r.score != null ? r.score : r.confidence) || 0,
        reason: r.reason || "",
      }))
      .sort((a, b) => a.judge_id - b.judge_id);
    const head = rows[0];
    const panel = {
      suggestion_id: Number(head.suggestion_id),
      panel_confidence: Number(
        head.panel_confidence != null ? head.panel_confidence : head.confidence
      ),
      panel_signal: String(head.panel_signal || "agree").toLowerCase(),
      judge_band: head.judge_band || "",
      judge_count: Number(head.judge_count) || votes.length,
    };
    if (!isFinite(panel.panel_confidence)) {
      // blend locally if API omitted panel fields
      let sum = 0;
      votes.forEach((v) => {
        if (v.verdict === "redact") sum += v.score;
        else if (v.verdict === "keep") sum += 100 - v.score;
        else sum += 50;
      });
      panel.panel_confidence = Math.round(sum / Math.max(votes.length, 1));
    }
    return { panel, votes };
  }

  async function fetchJudges(id) {
    if (cache.has(id)) return cache.get(id);
    try {
      const res = await fetch("/api/suggestions/" + id + "/judges", {
        headers: { Accept: "application/json" },
      });
      if (!res.ok) return null;
      const data = await res.json();
      const pack = normalizeVotes(extractRows(data));
      if (pack) cache.set(id, pack);
      return pack;
    } catch (_) {
      return null;
    }
  }

  function paintWhyCard(pack) {
    const card = ensureWhyCard();
    if (!card) return;
    if (!pack) {
      card.classList.remove("on");
      card.hidden = true;
      return;
    }
    const { panel, votes } = pack;
    card.hidden = false;
    card.classList.add("on");
    card.dataset.suggestionId = String(panel.suggestion_id);

    const badge = card.querySelector("#judge-badge") || card.querySelector(".judge-badge");
    if (badge) {
      badge.textContent = panel.panel_signal;
      badge.dataset.signal = panel.panel_signal;
      badge.className = "judge-badge " + panel.panel_signal;
    }
    const conf = card.querySelector("#judge-conf") || card.querySelector(".judge-conf");
    if (conf) {
      conf.textContent = String(panel.panel_confidence);
      conf.dataset.conf = String(panel.panel_confidence);
      conf.style.color = confGradientColor(panel.panel_confidence);
    }

    const panelEl = card.querySelector("#judge-panel") || card.querySelector(".judge-panel");
    if (!panelEl) return;
    // Rebuild vote lines (max 3, one line each)
    panelEl.innerHTML = votes
      .slice(0, 3)
      .map((v) => {
        const sc = confGradientColor(v.score);
        return (
          '<div class="judge-vote" data-judge="' +
          escapeAttr(v.judge_name) +
          '" role="listitem">' +
          '<span class="jv-name">' +
          escapeHtml(v.judge_name) +
          "</span>" +
          '<span class="jv-verdict ' +
          escapeAttr(v.verdict) +
          '">' +
          escapeHtml(v.verdict) +
          "</span>" +
          '<span class="jv-score" style="color:' +
          sc +
          '">' +
          v.score +
          "</span>" +
          '<span class="jv-reason" title="' +
          escapeAttr(v.reason) +
          '">' +
          escapeHtml(v.reason) +
          "</span>" +
          "</div>"
        );
      })
      .join("");
  }

  function paintRowChips(row, pack) {
    if (!row || !pack) return;
    const st = row.querySelector(".st");
    if (!st) return;
    let chips = row.querySelector(".judge-chips");
    if (!chips) {
      chips = document.createElement("div");
      chips.className = "judge-chips";
      st.appendChild(chips);
    }
    const { panel, votes } = pack;
    const parts = [
      '<span class="judge-chip-badge ' +
        escapeAttr(panel.panel_signal) +
        '">' +
        escapeHtml(panel.panel_signal) +
        "</span>",
    ];
    votes.slice(0, 3).forEach((v) => {
      const sc = confGradientColor(v.score);
      parts.push(
        '<span class="judge-chip" title="' +
          escapeAttr(v.reason) +
          '">' +
          '<span class="jc-n">' +
          escapeHtml(v.judge_name.slice(0, 1)) +
          "</span>" +
          '<span class="jc-v ' +
          escapeAttr(v.verdict) +
          '">' +
          escapeHtml(v.verdict.slice(0, 1)) +
          "</span>" +
          '<span class="jc-s" style="color:' +
          sc +
          '">' +
          v.score +
          "</span>" +
          "</span>"
      );
    });
    chips.innerHTML = parts.join("");

    // Gradient the row confidence number (60→95 ramp)
    const confEl = row.querySelector(".conf");
    if (confEl) {
      const n = Number(
        panel.panel_confidence != null ? panel.panel_confidence : row.dataset.conf
      );
      if (isFinite(n)) {
        confEl.classList.add("judge-grad");
        confEl.style.color = confGradientColor(n);
        confEl.title =
          "judge confidence " +
          n +
          " · " +
          panel.panel_signal +
          (row.dataset.conf ? " · seed " + row.dataset.conf : "");
      }
    }
  }

  function escapeHtml(str) {
    return String(str == null ? "" : str)
      .replace(/&/g, "&amp;")
      .replace(/</g, "&lt;")
      .replace(/>/g, "&gt;")
      .replace(/"/g, "&quot;");
  }
  function escapeAttr(str) {
    return escapeHtml(str).replace(/'/g, "&#39;");
  }

  function isFlaggedRow(row) {
    if (!row) return false;
    if (row.classList.contains("fr")) return true;
    if (row.dataset.band === "flagged") return true;
    const conf = Number(row.dataset.conf);
    return isFinite(conf) && conf < 60;
  }

  function currentSuggestionId() {
    const cur = document.querySelector(".sugg.current[data-id]");
    if (cur) return Number(cur.dataset.id);
    // hash #s123
    const m = (location.hash || "").match(/^#s(\d+)/);
    if (m) return Number(m[1]);
    return null;
  }

  async function refreshRows() {
    const rows = document.querySelectorAll(".sugg[data-id]");
    const jobs = [];
    rows.forEach((row) => {
      if (!isFlaggedRow(row)) {
        // still gradient non-flagged conf numbers lightly
        const confEl = row.querySelector(".conf");
        if (confEl && row.dataset.conf != null) {
          const n = Number(row.dataset.conf);
          if (isFinite(n) && n >= 60) {
            confEl.classList.add("judge-grad");
            confEl.style.color = confGradientColor(n);
          }
        }
        return;
      }
      const id = Number(row.dataset.id);
      if (!id) return;
      jobs.push(
        fetchJudges(id).then((pack) => {
          if (pack) paintRowChips(row, pack);
        })
      );
    });
    await Promise.all(jobs);
  }

  async function refreshCurrent() {
    const id = currentSuggestionId();
    const cur = document.querySelector(".sugg.current[data-id]");
    if (!id || !cur || !isFlaggedRow(cur)) {
      paintWhyCard(null);
      lastCurrentId = null;
      return;
    }
    if (id === lastCurrentId && cache.has(id)) {
      paintWhyCard(cache.get(id));
      return;
    }
    lastCurrentId = id;
    const pack = await fetchJudges(id);
    paintWhyCard(pack);
  }

  function scheduleRefresh() {
    // coalesce mutation storms from review.js re-renders
    if (scheduleRefresh._t) clearTimeout(scheduleRefresh._t);
    scheduleRefresh._t = setTimeout(() => {
      refreshRows();
      refreshCurrent();
    }, 40);
  }

  function boot() {
    // Only on review surface
    if (!document.getElementById("q-list") && !document.querySelector(".queue")) return;
    ensureCss();
    ensureWhyCard();

    // Initial paint after review.js hydrates
    scheduleRefresh();
    setTimeout(scheduleRefresh, 200);
    setTimeout(scheduleRefresh, 800);

    const qList = document.getElementById("q-list");
    if (qList && typeof MutationObserver !== "undefined") {
      observer = new MutationObserver(scheduleRefresh);
      observer.observe(qList, { childList: true, subtree: true, attributes: true, attributeFilter: ["class", "data-id"] });
    }

    document.addEventListener(
      "click",
      (e) => {
        if (e.target && e.target.closest && e.target.closest(".sugg[data-id]")) {
          setTimeout(refreshCurrent, 30);
        }
      },
      true
    );

    document.addEventListener("keydown", (e) => {
      if (e.key === "j" || e.key === "k" || e.key === "ArrowDown" || e.key === "ArrowUp") {
        setTimeout(refreshCurrent, 40);
      }
    });
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", boot);
  } else {
    boot();
  }

  // Export for debugging / review.js optional integration
  window.ClosureJudges = {
    fetchJudges,
    confGradientColor,
    refresh: scheduleRefresh,
    cache,
  };
})();
