/**
 * Closure shared client primitives → window.Closure
 * Load first: <script src="/static/common.js"></script>
 */
(function (global) {
  "use strict";

  var DEFAULT_ACTOR = "A. Subbarao";

  function escapeHtml(str) {
    return String(str == null ? "" : str)
      .replace(/&/g, "&amp;")
      .replace(/</g, "&lt;")
      .replace(/>/g, "&gt;")
      .replace(/"/g, "&quot;");
  }

  /** Soft {ok,status,data,raw,text,url}. throwOnError → throws + returns data (bulk). */
  async function fetchJson(url, opts) {
    opts = opts || {};
    if (String(opts.method || "GET").toUpperCase() === "POST") {
      opts = Object.assign({}, opts);
      if (opts.body == null) opts.body = "{}";
      opts.headers = Object.assign(
        { "Content-Type": "application/json" },
        opts.headers || {}
      );
    }
    var res = await fetch(url, opts);
    var text = await res.text();
    var data = null;
    try {
      data = text ? JSON.parse(text) : null;
    } catch (e) {
      data = opts.throwOnError ? { raw: text } : text;
    }
    if (opts.throwOnError) {
      if (!res.ok) {
        var err = new Error("HTTP " + res.status + " for " + url);
        err.status = res.status;
        err.body = data;
        throw err;
      }
      return data;
    }
    return { ok: res.ok, status: res.status, data: data, raw: text, text: text, url: url };
  }

  /** Force POST + JSON headers + body '{}'. Response or {ok:false,status:0,error}. */
  async function postJson(url, opts) {
    opts = opts || {};
    try {
      return await fetch(url, {
        method: "POST",
        headers: Object.assign(
          { Accept: "application/json", "Content-Type": "application/json" },
          opts.headers || {}
        ),
        body: opts.body != null ? opts.body : "{}",
      });
    } catch (err) {
      return { ok: false, status: 0, error: err };
    }
  }

  function decisionQuery(opts) {
    var q = new URLSearchParams();
    q.set("status", opts.status);
    if (opts.action != null && opts.action !== false) {
      q.set("action", opts.action === true ? opts.status : opts.action);
    }
    if (opts.actor) q.set("actor", opts.actor);
    if (opts.reason) q.set("reason", opts.reason);
    return q.toString();
  }

  async function postSuggestionDecision(id, opts) {
    opts = opts || {};
    var qs = decisionQuery(opts);
    var res = await fetchJson("/api/suggestions/" + id + "/decision?" + qs, {
      method: "POST",
      throwOnError: !!opts.throwOnError,
    });
    if (!opts.throwOnError && opts.legacyFallback && res && !res.ok) {
      res = await fetchJson("/suggestions/" + id + "/decision?" + qs, {
        method: "POST",
      });
    }
    return res;
  }

  async function postEntityDecision(entityId, opts) {
    opts = opts || {};
    return fetchJson(
      "/api/entities/" + entityId + "/decision?" + decisionQuery(opts),
      { method: "POST", throwOnError: !!opts.throwOnError }
    );
  }

  /**
   * Payload → row array. keys default suggestions/rows/judges/data.
   * unwrapSingleton: unwrap [{suggestions:[…]}] (reject only; default true).
   */
  function asRows(payload, opts) {
    opts = opts || {};
    var keys = opts.keys || ["suggestions", "rows", "judges", "data"];
    var unwrap = opts.unwrapSingleton !== false;
    if (payload == null) return [];
    if (Array.isArray(payload)) {
      if (unwrap && payload.length === 1 && payload[0] && typeof payload[0] === "object") {
        for (var i = 0; i < keys.length; i++) {
          if (Array.isArray(payload[0][keys[i]])) return payload[0][keys[i]];
        }
      }
      return payload;
    }
    if (typeof payload === "object") {
      for (var j = 0; j < keys.length; j++) {
        if (Array.isArray(payload[keys[j]])) return payload[keys[j]];
      }
      if (
        payload.id != null ||
        payload.judge_name ||
        payload.text != null
      ) {
        return [payload];
      }
    }
    return [];
  }

  /** (conf, explicit) or row {band,confidence}. */
  function bandOf(confOrRow, explicit) {
    if (confOrRow != null && typeof confOrRow === "object" && !Array.isArray(confOrRow)) {
      if (arguments.length === 1) {
        if (confOrRow.band) return confOrRow.band;
        confOrRow = confOrRow.confidence;
      }
    }
    if (explicit === "high" || explicit === "review" || explicit === "flagged") return explicit;
    var n = Number(confOrRow);
    if (n >= 90) return "high";
    if (n >= 60) return "review";
    return "flagged";
  }

  /** Band string, numeric conf, or row → h|m|l. */
  function confClass(bandOrConf) {
    if (bandOrConf != null && typeof bandOrConf === "object" && !Array.isArray(bandOrConf)) {
      return confClass(bandOf(bandOrConf));
    }
    if (bandOrConf === "high") return "h";
    if (bandOrConf === "review") return "m";
    if (bandOrConf === "flagged") return "l";
    var c = Number(bandOrConf);
    if (Number.isFinite(c)) {
      if (c >= 90) return "h";
      if (c >= 60) return "m";
      return "l";
    }
    return "l";
  }

  function isFlagged(row) {
    if (!row) return false;
    return row.band === "flagged" || (row.confidence != null && Number(row.confidence) < 60);
  }

  /**
   * caseInsensitive default true; tokenFallback (bulk) tries first word on miss.
   * Empty ctx: "" unless tokenFallback → escapeHtml(text||'—').
   */
  function highlightContext(ctx, text, opts) {
    opts = opts || {};
    var caseInsensitive = opts.caseInsensitive !== false;
    var tokenFallback = !!opts.tokenFallback;
    ctx = ctx == null ? "" : String(ctx);
    text = text == null ? "" : String(text);
    if (!ctx) return tokenFallback ? escapeHtml(text || "—") : "";
    if (!text) return escapeHtml(ctx);
    var hay = caseInsensitive ? ctx.toLowerCase() : ctx;
    var needle = caseInsensitive ? text.toLowerCase() : text;
    var i = hay.indexOf(needle);
    var matchLen = text.length;
    if (i < 0 && tokenFallback) {
      var tok = text.split(/\s+/)[0];
      if (tok) {
        var ti = hay.indexOf(caseInsensitive ? tok.toLowerCase() : tok);
        if (ti >= 0) {
          i = ti;
          matchLen = tok.length;
        }
      }
    }
    if (i < 0) return escapeHtml(ctx);
    return (
      escapeHtml(ctx.slice(0, i)) +
      "<em>" +
      escapeHtml(ctx.slice(i, i + matchLen)) +
      "</em>" +
      escapeHtml(ctx.slice(i + matchLen))
    );
  }

  function globToRegExp(pattern) {
    var p = String(pattern || "").trim();
    if (!p) return null;
    var re = "";
    for (var i = 0; i < p.length; i++) {
      var c = p[i];
      if (c === "*") re += ".*";
      else if (c === "?") re += ".";
      else if ("\\.^$+()[]{}|".indexOf(c) >= 0) re += "\\" + c;
      else re += c;
    }
    try {
      return new RegExp("^" + re + "$", "i");
    } catch (e) {
      return null;
    }
  }

  function readBoot() {
    try {
      var el = document.getElementById("boot-data");
      if (el) return JSON.parse(el.textContent);
    } catch (_) {}
    return {};
  }

  /** prefer:'boot'(default,history) | 'dataset'(geo). opts.root for dataset. */
  function bootCaseId(opts) {
    opts = opts || {};
    function fromEl(el) {
      if (el && el.dataset && el.dataset.caseId) {
        var s = String(el.dataset.caseId).trim();
        if (s) return s;
      }
      return null;
    }
    function fromBoot() {
      var boot = readBoot();
      if (boot && boot.caseId != null && String(boot.caseId).trim() !== "") return String(boot.caseId);
      return null;
    }
    function fromAttr() {
      var el = document.querySelector("[data-case-id]");
      if (el) {
        var s = String(el.getAttribute("data-case-id") || "").trim();
        if (s) return s;
      }
      return null;
    }
    function fromPath() {
      var m = /^\/cases\/([^/]+)/.exec(
        (typeof window !== "undefined" && window.location.pathname) || ""
      );
      return m ? decodeURIComponent(m[1]) : null;
    }
    if (opts.prefer === "dataset") {
      return fromEl(opts.root) || fromEl(document.body) || fromBoot() || fromPath() || "1";
    }
    return fromBoot() || fromEl(document.body) || fromAttr() || fromPath() || "1";
  }

  function bootActor(def) {
    var boot = readBoot();
    if (boot && boot.actor) return String(boot.actor);
    if (typeof document !== "undefined" && document.body && document.body.dataset && document.body.dataset.actor) {
      return String(document.body.dataset.actor);
    }
    return def != null ? def : DEFAULT_ACTOR;
  }

  function isEditableTarget(el) {
    if (!el) return false;
    var tag = el.tagName || "";
    return tag === "INPUT" || tag === "TEXTAREA" || tag === "SELECT" || !!el.isContentEditable;
  }

  function openHistory() {
    if (global.__history && typeof global.__history.open === "function") {
      global.__history.open();
      return true;
    }
    var fab = typeof document !== "undefined" ? document.getElementById("hist-fab") : null;
    if (fab) {
      fab.click();
      return true;
    }
    return false;
  }

  global.Closure = {
    DEFAULT_ACTOR: DEFAULT_ACTOR,
    escapeHtml: escapeHtml,
    esc: escapeHtml,
    fetchJson: fetchJson,
    postJson: postJson,
    postSuggestionDecision: postSuggestionDecision,
    postEntityDecision: postEntityDecision,
    asRows: asRows,
    bandOf: bandOf,
    confClass: confClass,
    isFlagged: isFlagged,
    highlightContext: highlightContext,
    globToRegExp: globToRegExp,
    readBoot: readBoot,
    bootCaseId: bootCaseId,
    bootActor: bootActor,
    isEditableTarget: isEditableTarget,
    openHistory: openHistory,
  };
})(typeof window !== "undefined" ? window : globalThis);
