/**
 * Closure — entity bulk-review sheet
 * Served at GET /ui/bulk?entity=<id>&case=<id>
 * Data: GET /api/cases/:id/suggestions (filter entity in JS)
 * Mutate: POST /api/entities/:id/decision and/or /api/suggestions/:id/decision
 */
(function () {
  'use strict';

  var ACTOR = 'A. Subbarao';
  var PREVIEW_LIMIT = 5;

  var params = new URLSearchParams(window.location.search);
  var entityId = num(params.get('entity'));
  var caseIdParam = num(params.get('case'));
  /** Optional document scope from library: ?docs=1,2,3 */
  var docsParam = String(params.get('docs') || '')
    .split(',')
    .map(function (x) { return num(x); })
    .filter(function (x) { return x != null; });
  /** @type {Set<number>|null} */
  var docScope = docsParam.length ? new Set(docsParam) : null;
  var pageFrom = num(params.get('page_from'));
  var pageTo = num(params.get('page_to'));
  var docGlob = params.get('glob') || '';

  /** @type {Array<Object>} */
  var allRows = [];
  /** @type {Array<Object>} unscoped raw rows */
  var rawRows = [];
  /** @type {Map<number, boolean>} suggestionId -> checked */
  var checked = new Map();
  /** @type {Map<string, boolean>} docKey -> expanded */
  var expanded = new Map();
  var bandFilter = 'all';
  var caseId = caseIdParam;
  var caseNo = '';
  var entityText = '';
  var entityKind = '';
  var busy = false;
  /** @type {{ ids: number[], priorStatus: string } | null} */
  var lastUndo = null;
  /** focused row id for j/k navigation */
  var focusId = null;

  var el = {
    title: document.getElementById('entity-title'),
    kind: document.getElementById('entity-kind'),
    body: document.getElementById('sheet-body'),
    flagCallout: document.getElementById('flag-callout'),
    flagText: document.getElementById('flag-callout-text'),
    btnAccept: document.getElementById('btn-accept'),
    btnReject: document.getElementById('btn-reject'),
    btnClose: document.getElementById('btn-close'),
    selCount: document.getElementById('sel-count'),
    selProp: document.getElementById('sel-prop'),
    status: document.getElementById('bulk-status'),
    tN: document.getElementById('t-n'),
    tD: document.getElementById('t-d'),
    tS: document.getElementById('t-s'),
    tX: document.getElementById('t-x'),
    tR: document.getElementById('t-r'),
    bcAll: document.getElementById('bc-all'),
    bcHigh: document.getElementById('bc-high'),
    bcReview: document.getElementById('bc-review'),
    bcFlagged: document.getElementById('bc-flagged'),
    bcDecided: document.getElementById('bc-decided'),
    bands: document.getElementById('bands-row'),
  };

  function num(v) {
    if (v == null || v === '') return null;
    var n = Number(v);
    return Number.isFinite(n) ? n : null;
  }

  function esc(s) {
    return String(s == null ? '' : s)
      .replace(/&/g, '&amp;')
      .replace(/</g, '&lt;')
      .replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;');
  }

  function showStatus(msg, isErr, undoPayload) {
    var msgEl = document.getElementById('bulk-status-msg');
    var undoBtn = document.getElementById('bulk-undo');
    if (msgEl) msgEl.textContent = msg;
    else el.status.textContent = msg;
    el.status.classList.toggle('err', !!isErr);
    el.status.classList.add('show');
    if (undoPayload && undoPayload.ids && undoPayload.ids.length) {
      lastUndo = undoPayload;
      if (undoBtn) undoBtn.hidden = false;
    } else {
      if (!undoPayload) {
        /* keep lastUndo if just a status flash without clearing */
      }
      if (isErr) {
        lastUndo = null;
        if (undoBtn) undoBtn.hidden = true;
      }
    }
    clearTimeout(showStatus._t);
    showStatus._t = setTimeout(function () {
      el.status.classList.remove('show');
      if (undoBtn) undoBtn.hidden = true;
      // retain lastUndo for keyboard a bit longer
    }, 8000);
  }

  async function undoLast() {
    if (!lastUndo || !lastUndo.ids || !lastUndo.ids.length || busy) {
      showStatus('Nothing to undo', true);
      return;
    }
    busy = true;
    updateChrome();
    try {
      var ids = lastUndo.ids.slice();
      var prior = lastUndo.priorStatus || 'pending';
      for (var i = 0; i < ids.length; i++) {
        var u =
          '/api/suggestions/' +
          ids[i] +
          '/decision?status=' +
          encodeURIComponent(prior) +
          '&actor=' +
          encodeURIComponent(ACTOR) +
          '&reason=' +
          encodeURIComponent('undo bulk');
        await fetchJson(u, { method: 'POST' });
      }
      lastUndo = null;
      showStatus('Restored to pending · ' + ids.length + ' instance' + (ids.length === 1 ? '' : 's'));
      await reload();
    } catch (err) {
      showStatus('Undo failed: ' + (err.message || err), true);
    } finally {
      busy = false;
      updateChrome();
      render();
    }
  }

  function isDecided(row) {
    return row.status === 'accepted' || row.status === 'rejected';
  }

  function isFlagged(row) {
    return row.band === 'flagged' || (row.confidence != null && Number(row.confidence) < 60);
  }

  function isEligibleDefault(row) {
    return !isDecided(row) && !isFlagged(row);
  }

  function docKey(row) {
    return String(row.document_id != null ? row.document_id : row.filename || 'unknown');
  }

  function docLabel(row) {
    var name = row.filename || row.document_filename || row.doc_filename;
    if (name) return String(name).replace(/\.pdf$/i, '');
    return 'document_' + (row.document_id != null ? row.document_id : '?');
  }

  function confClass(c) {
    c = Number(c);
    if (c >= 90) return 'h';
    if (c >= 60) return 'm';
    return 'l';
  }

  function flagWhy(row) {
    if (row.flag_tag) return String(row.flag_tag).replace(/_/g, ' ');
    if (row.reason) {
      var r = String(row.reason);
      if (r.length > 28) r = r.slice(0, 26) + '…';
      return r;
    }
    return 'flagged';
  }

  function highlightContext(ctx, matchText) {
    ctx = String(ctx || '');
    matchText = String(matchText || '');
    if (!ctx) return esc(matchText || '—');
    if (!matchText) return esc(ctx);
    var lower = ctx.toLowerCase();
    var m = matchText.toLowerCase();
    var i = lower.indexOf(m);
    if (i < 0) {
      // try first token
      var tok = matchText.split(/\s+/)[0];
      if (tok) {
        i = lower.indexOf(tok.toLowerCase());
        if (i >= 0) matchText = ctx.slice(i, i + tok.length);
      }
    }
    if (i < 0) return esc(ctx);
    return (
      esc(ctx.slice(0, i)) +
      '<em>' +
      esc(ctx.slice(i, i + matchText.length)) +
      '</em>' +
      esc(ctx.slice(i + matchText.length))
    );
  }

  function formatKindCase(kind, cno) {
    var k = String(kind || 'ENTITY').trim();
    // "PERSON · SUBJECT" → "PERSON · SUBJECT OF CASE …"
    // "CITATION · NOT PII" → "CITATION · NOT PII · SUBJECT OF CASE …"
    // avoid "NOT SUBJECT PII" matching the SUBJECT branch
    if (/\bSUBJECT\b/i.test(k) && !/\bNOT\s+SUBJECT\b/i.test(k)) {
      return k + ' OF CASE ' + cno;
    }
    return k + ' · SUBJECT OF CASE ' + cno;
  }

  async function fetchJson(url, opts) {
    opts = opts || {};
    // quackapi POST requires a body (bare POST → 400). Always send JSON {}.
    if (opts.method && String(opts.method).toUpperCase() === 'POST') {
      opts.headers = Object.assign(
        { 'Content-Type': 'application/json' },
        opts.headers || {}
      );
      if (opts.body == null) opts.body = '{}';
    }
    var res = await fetch(url, opts);
    var text = await res.text();
    var data = null;
    try {
      data = text ? JSON.parse(text) : null;
    } catch (e) {
      data = { raw: text };
    }
    if (!res.ok) {
      var err = new Error('HTTP ' + res.status + ' for ' + url);
      err.status = res.status;
      err.body = data;
      throw err;
    }
    return data;
  }

  /** Normalize API payload to a row array (handles list or {suggestions:[]}). */
  function asRows(payload) {
    if (Array.isArray(payload)) return payload;
    if (payload && Array.isArray(payload.suggestions)) return payload.suggestions;
    if (payload && Array.isArray(payload.rows)) return payload.rows;
    if (payload && typeof payload === 'object') {
      // single row object
      if (payload.id != null && (payload.entity_id != null || payload.document_id != null)) {
        return [payload];
      }
    }
    return [];
  }

  async function loadCaseSuggestions(cid) {
    var data = await fetchJson('/api/cases/' + cid + '/suggestions');
    return asRows(data);
  }

  async function resolveCaseAndLoad() {
    if (!entityId && !caseIdParam) {
      throw new Error('Pass ?entity=<id> and/or ?case=<id>');
    }

    if (caseIdParam) {
      caseId = caseIdParam;
      var rows = await loadCaseSuggestions(caseId);
      return filterEntity(rows);
    }

    // entity only — probe cases 1..8 until we find matching suggestions
    var lastErr = null;
    for (var cid = 1; cid <= 8; cid++) {
      try {
        var all = await loadCaseSuggestions(cid);
        var filtered = all.filter(function (r) {
          return Number(r.entity_id) === entityId;
        });
        if (filtered.length) {
          caseId = cid;
          return filtered;
        }
        // also keep going if case has data but not this entity
      } catch (e) {
        lastErr = e;
        if (e.status === 404 && cid === 1) {
          // API missing entirely
          throw e;
        }
      }
    }
    if (lastErr) throw lastErr;
    caseId = 1;
    return [];
  }

  function globToRegExp(pattern) {
    var p = String(pattern || '').trim();
    if (!p) return null;
    var re = '';
    for (var i = 0; i < p.length; i++) {
      var c = p[i];
      if (c === '*') re += '.*';
      else if (c === '?') re += '.';
      else if ('\\.^$+()[]{}|'.indexOf(c) >= 0) re += '\\' + c;
      else re += c;
    }
    try {
      return new RegExp('^' + re + '$', 'i');
    } catch (e) {
      return null;
    }
  }

  function matchesGlob(row, pattern) {
    if (!pattern || !String(pattern).trim()) return true;
    var re = globToRegExp(pattern);
    var name = docLabel(row);
    var full = name + '.pdf';
    if (re) return re.test(name) || re.test(full);
    var q = String(pattern).trim().toLowerCase();
    return name.toLowerCase().indexOf(q) >= 0;
  }

  function filterEntity(rows) {
    var out = rows.slice();
    if (entityId) {
      out = out.filter(function (r) {
        return Number(r.entity_id) === entityId;
      });
    }
    return applyScope(out);
  }

  function applyScope(rows) {
    var out = rows;
    if (docScope && docScope.size) {
      out = out.filter(function (r) {
        return docScope.has(Number(r.document_id));
      });
    }
    if (docGlob) {
      out = out.filter(function (r) {
        return matchesGlob(r, docGlob);
      });
    }
    if (pageFrom != null) {
      out = out.filter(function (r) {
        return Number(r.page_no) >= pageFrom;
      });
    }
    if (pageTo != null) {
      out = out.filter(function (r) {
        return Number(r.page_no) <= pageTo;
      });
    }
    return out;
  }

  function renderDocRollups() {
    var host = document.getElementById('doc-rollups');
    var meta = document.getElementById('doc-scope-meta');
    if (!host) return;
    var groups = groupByDoc(allRows);
    if (!groups.length) {
      host.innerHTML = '';
      if (meta) meta.textContent = 'no documents in scope';
      return;
    }
    if (meta) {
      meta.textContent =
        groups.length +
        ' document' +
        (groups.length === 1 ? '' : 's') +
        ' in scope' +
        (docGlob ? ' · glob ' + docGlob : '') +
        (pageFrom != null || pageTo != null
          ? ' · pages ' + (pageFrom || 1) + '–' + (pageTo || '∞')
          : '');
    }
    host.innerHTML = groups
      .map(function (g) {
        var pend = g.rows.filter(function (r) {
          return !isDecided(r);
        }).length;
        var total = g.rows.length;
        var done = total - pend;
        var pct = total ? Math.round((100 * done) / total) : 0;
        var flagN = g.rows.filter(function (r) {
          return isFlagged(r) && !isDecided(r);
        }).length;
        return (
          '<span style="display:inline-flex;align-items:center;gap:6px;padding:4px 10px;border:1px solid var(--line);border-radius:14px;font-size:11px;background:var(--surface-2)">' +
          '<b style="font-family:var(--mono)">' +
          esc(g.label) +
          '</b>' +
          '<span style="color:var(--mut);font-family:var(--mono)">' +
          done +
          '/' +
          total +
          ' · ' +
          pct +
          '%</span>' +
          (flagN
            ? '<span style="color:var(--red-text);font-weight:700">⚑' + flagN + '</span>'
            : '') +
          '<span style="width:40px;height:4px;background:var(--line);border-radius:2px;overflow:hidden;display:inline-block"><i style="display:block;height:100%;width:' +
          pct +
          '%;background:var(--ok)"></i></span></span>'
        );
      })
      .join('');
  }

  function inferMeta(rows) {
    if (!rows.length) {
      entityText = entityId != null ? 'Entity #' + entityId : 'Entity';
      entityKind = '—';
      caseNo = caseId != null ? String(caseId) : '—';
      return;
    }
    var r0 = rows[0];
    entityText =
      r0.entity_text ||
      r0.canonical_text ||
      r0.text ||
      (entityId != null ? 'Entity #' + entityId : 'Entity');
    entityKind = r0.kind || r0.entity_kind || '—';
    caseNo =
      r0.case_no ||
      r0.case_number ||
      (caseId === 1 ? '24-000117' : caseId != null ? String(caseId) : '—');
    if (!entityId && r0.entity_id != null) entityId = Number(r0.entity_id);
  }

  function initChecks(rows) {
    checked.clear();
    rows.forEach(function (r) {
      if (isDecided(r)) {
        // not selectable
        return;
      }
      // default: non-flagged pending checked; flagged unchecked
      checked.set(Number(r.id), isEligibleDefault(r));
    });
  }

  function selectedRows() {
    return allRows.filter(function (r) {
      return checked.get(Number(r.id)) === true && !isDecided(r);
    });
  }

  function selectedCount() {
    return selectedRows().length;
  }

  function counts() {
    var n = allRows.length;
    var docs = new Set(allRows.map(docKey));
    var s = selectedCount();
    var x = allRows.filter(function (r) {
      return isFlagged(r) && !isDecided(r);
    }).length;
    var r = allRows.filter(isDecided).length;
    var high = allRows.filter(function (row) {
      return row.band === 'high' || (Number(row.confidence) >= 90 && !isFlagged(row));
    }).length;
    var review = allRows.filter(function (row) {
      return row.band === 'review' || (Number(row.confidence) >= 60 && Number(row.confidence) < 90);
    }).length;
    var flagged = allRows.filter(isFlagged).length;
    return { n: n, d: docs.size, s: s, x: x, r: r, high: high, review: review, flagged: flagged };
  }

  function updateChrome() {
    var c = counts();
    el.tN.textContent = String(c.n);
    el.tD.textContent = String(c.d);
    el.tS.textContent = String(c.s);
    el.tX.textContent = String(c.x);
    el.tR.textContent = String(c.r);

    el.bcAll.textContent = String(c.n);
    el.bcHigh.textContent = String(c.high);
    el.bcReview.textContent = String(c.review);
    el.bcFlagged.textContent = String(c.flagged);
    el.bcDecided.textContent = String(c.r);

    var sel = c.s;
    el.selCount.textContent =
      sel === 1 ? '1 instance selected' : sel + ' instances selected';
    var selDocs = new Set(selectedRows().map(docKey));
    if (sel > 0 && selDocs.size > 0) {
      el.selProp.hidden = false;
      el.selProp.textContent =
        '✓ propagates to ' + selDocs.size + ' document' + (selDocs.size === 1 ? '' : 's') +
        ' · one audit event per instance';
    } else {
      el.selProp.hidden = true;
    }

    el.btnAccept.textContent = 'Accept ' + sel + ' — lay the ink';
    el.btnAccept.disabled = busy || sel === 0;
    el.btnReject.textContent =
      sel === 0 ? 'Reject selected (0)' : 'Reject selected (' + sel + ')';
    el.btnReject.disabled = busy || sel === 0;

    if (c.x > 0) {
      el.flagCallout.hidden = false;
      el.flagText.innerHTML =
        '<b>' +
        c.x +
        ' flagged items</b> are excluded from bulk accept — they require individual decisions. They are shown below with a red background.';
    } else {
      el.flagCallout.hidden = true;
    }

    renderDocRollups();
    document.title = 'Closure — Bulk review · ' + entityText;
  }

  function passesBand(row) {
    if (bandFilter === 'all') return true;
    if (bandFilter === 'decided') return isDecided(row);
    if (bandFilter === 'flagged') return isFlagged(row) && !isDecided(row);
    if (bandFilter === 'high') {
      return !isDecided(row) && (row.band === 'high' || Number(row.confidence) >= 90);
    }
    if (bandFilter === 'review') {
      return (
        !isDecided(row) &&
        (row.band === 'review' ||
          (Number(row.confidence) >= 60 && Number(row.confidence) < 90))
      );
    }
    return true;
  }

  function groupByDoc(rows) {
    var map = new Map();
    rows.forEach(function (r) {
      var k = docKey(r);
      if (!map.has(k)) {
        map.set(k, { key: k, label: docLabel(r), rows: [] });
      }
      map.get(k).rows.push(r);
    });
    // stable sort by label
    return Array.from(map.values()).sort(function (a, b) {
      return a.label < b.label ? -1 : a.label > b.label ? 1 : 0;
    });
  }

  function renderRow(row) {
    var id = Number(row.id);
    var decided = isDecided(row);
    var flagged = isFlagged(row);
    var isChecked = !decided && checked.get(id) === true;
    var cls = 'inst';
    if (flagged && !decided) cls += ' flagged-exc';
    if (decided) cls += ' decided';

    var why = '';
    if (flagged && !decided) {
      why = '<span class="exc-why">' + esc(flagWhy(row)) + '</span>';
    } else if (decided && row.flag_tag) {
      why =
        '<span class="exc-why muted">' +
        esc(String(row.status)) +
        '</span>';
    } else if (decided) {
      why =
        '<span class="exc-why muted">' +
        esc(String(row.status)) +
        '</span>';
    }

    var conf = row.confidence != null ? Math.round(Number(row.confidence)) : '—';
    var page = row.page_no != null ? 'p.' + row.page_no : '';

    return (
      '<div class="' +
      cls +
      '" data-id="' +
      id +
      '">' +
      '<input type="checkbox" data-id="' +
      id +
      '"' +
      (isChecked ? ' checked' : '') +
      (decided || busy ? ' disabled' : '') +
      ' aria-label="Select instance ' +
      id +
      '">' +
      '<span class="inst-ctx">' +
      highlightContext(row.context, row.text) +
      '</span>' +
      why +
      '<span class="inst-pg">' +
      esc(page) +
      '</span>' +
      '<span class="inst-conf ' +
      confClass(row.confidence) +
      '">' +
      esc(String(conf)) +
      '</span>' +
      '</div>'
    );
  }

  function render() {
    updateChrome();

    if (!allRows.length) {
      el.body.innerHTML =
        '<div class="empty">No instances for this entity' +
        (entityId != null ? ' #' + entityId : '') +
        '.</div>';
      return;
    }

    var visible = allRows.filter(passesBand);
    if (!visible.length) {
      el.body.innerHTML = '<div class="empty">No instances in this band.</div>';
      return;
    }

    var groups = groupByDoc(visible);
    var html = '';

    groups.forEach(function (g) {
      var pages = g.rows.map(function (r) {
        return Number(r.page_no) || 0;
      });
      var minP = Math.min.apply(null, pages);
      var maxP = Math.max.apply(null, pages);
      var flagN = g.rows.filter(function (r) {
        return isFlagged(r) && !isDecided(r);
      }).length;
      var allDecided = g.rows.every(isDecided);
      var eligible = g.rows.filter(function (r) {
        return !isDecided(r);
      });
      var isExp = expanded.get(g.key) === true;
      var show = isExp || g.rows.length <= PREVIEW_LIMIT ? g.rows : g.rows.slice(0, PREVIEW_LIMIT);
      var hiddenN = g.rows.length - show.length;

      var meta =
        g.rows.length +
        ' instance' +
        (g.rows.length === 1 ? '' : 's') +
        (minP && maxP ? ' · pp. ' + minP + (minP !== maxP ? '–' + maxP : '') : '') +
        (flagN ? ' · ⚑ ' + flagN + ' flagged' : '') +
        (allDecided ? ' · all decided' : '');

      var selectLabel =
        flagN > 0 && eligible.length > flagN
          ? 'Select eligible only →'
          : 'Select all ' + eligible.length + ' in doc →';

      html += '<div class="doc-group" data-doc="' + esc(g.key) + '">';
      html +=
        '<div class="dg-head"' +
        (allDecided ? ' style="opacity:.65"' : '') +
        '>' +
        '<span class="dg-filename">' +
        esc(g.label) +
        '</span>' +
        '<span class="dg-meta">' +
        esc(meta) +
        '</span>';
      if (eligible.length && !allDecided) {
        html +=
          '<button type="button" class="dg-select-all" data-doc="' +
          esc(g.key) +
          '">' +
          esc(selectLabel) +
          '</button>';
      } else if (allDecided) {
        var accN = g.rows.filter(function (r) {
          return r.status === 'accepted';
        }).length;
        html +=
          '<span style="margin-left:auto;font-size:12px;font-weight:600;color:var(--ok)">✓ ' +
          accN +
          ' accepted</span>';
      }
      html += '</div>';

      show.forEach(function (r) {
        html += renderRow(r);
      });

      if (hiddenN > 0) {
        html +=
          '<button type="button" class="show-more" data-doc="' +
          esc(g.key) +
          '">Show ' +
          hiddenN +
          ' more instances in this document →</button>';
      }
      html += '</div>';
    });

    el.body.innerHTML = html;
  }

  function setCheck(id, value) {
    id = Number(id);
    var row = allRows.find(function (r) {
      return Number(r.id) === id;
    });
    if (!row || isDecided(row)) return;
    checked.set(id, !!value);
  }

  function onBodyClick(e) {
    var t = e.target;
    if (!t) return;

    // show more
    if (t.classList && t.classList.contains('show-more')) {
      expanded.set(t.getAttribute('data-doc'), true);
      render();
      return;
    }

    // select all eligible in doc (non-flagged preferred; if already all eligible checked, select flagged too? — only non-flagged pending)
    if (t.classList && t.classList.contains('dg-select-all')) {
      var dk = t.getAttribute('data-doc');
      var groupRows = allRows.filter(function (r) {
        return docKey(r) === dk && !isDecided(r);
      });
      var eligibleOnly = groupRows.filter(function (r) {
        return !isFlagged(r);
      });
      var target = eligibleOnly.length ? eligibleOnly : groupRows;
      var allOn = target.every(function (r) {
        return checked.get(Number(r.id)) === true;
      });
      target.forEach(function (r) {
        checked.set(Number(r.id), !allOn);
      });
      // when selecting eligible, leave flagged unchecked
      if (!allOn) {
        groupRows
          .filter(isFlagged)
          .forEach(function (r) {
            checked.set(Number(r.id), false);
          });
      }
      render();
      return;
    }

    // checkbox
    if (t.matches && t.matches('input[type=checkbox][data-id]')) {
      setCheck(t.getAttribute('data-id'), t.checked);
      updateChrome();
      return;
    }

    // row click toggles checkbox
    var row = t.closest && t.closest('.inst[data-id]');
    if (row) {
      var id = row.getAttribute('data-id');
      var cb = row.querySelector('input[type=checkbox]');
      if (cb && !cb.disabled) {
        cb.checked = !cb.checked;
        setCheck(id, cb.checked);
        updateChrome();
      }
    }
  }

  function onBandClick(e) {
    var btn = e.target.closest && e.target.closest('.band-tab');
    if (!btn) return;
    bandFilter = btn.getAttribute('data-band') || 'all';
    Array.prototype.forEach.call(el.bands.querySelectorAll('.band-tab'), function (b) {
      b.classList.toggle('active', b === btn);
    });
    render();
  }

  /**
   * Accept strategy:
   * - If selection == all non-flagged pending for this entity (and no flagged checked),
   *   POST /api/entities/:id/decision?status=accepted (backend excludes flagged).
   * - Otherwise fan-out POST /api/suggestions/:id/decision for each checked row
   *   so N matches the button contract exactly.
   */
  async function decide(status) {
    if (busy) return;
    var sel = selectedRows();
    if (!sel.length) return;

    busy = true;
    updateChrome();
    render();

    var results = [];
    var decidedIds = sel.map(function (r) {
      return Number(r.id);
    });
    try {
      var pendingNonFlagged = allRows.filter(function (r) {
        return !isDecided(r) && !isFlagged(r);
      });
      var selIds = new Set(decidedIds);
      var onlyEligible =
        status === 'accepted' &&
        entityId != null &&
        sel.every(function (r) {
          return !isFlagged(r);
        }) &&
        pendingNonFlagged.length > 0 &&
        pendingNonFlagged.every(function (r) {
          return selIds.has(Number(r.id));
        }) &&
        sel.length === pendingNonFlagged.length;

      // quackapi requires every $param named in the route — always pass status + actor
      if (onlyEligible) {
        var url =
          '/api/entities/' +
          entityId +
          '/decision?status=' +
          encodeURIComponent(status) +
          '&actor=' +
          encodeURIComponent(ACTOR);
        var body = await fetchJson(url, { method: 'POST' });
        results.push({ mode: 'entity', url: url, body: body });
      } else {
        for (var i = 0; i < sel.length; i++) {
          var row = sel[i];
          var u =
            '/api/suggestions/' +
            row.id +
            '/decision?status=' +
            encodeURIComponent(status) +
            '&actor=' +
            encodeURIComponent(ACTOR);
          var b = await fetchJson(u, { method: 'POST' });
          results.push({ mode: 'suggestion', id: row.id, url: u, body: b });
        }
      }

      var verb = status === 'accepted' ? 'Accepted' : 'Rejected';
      showStatus(
        verb + ' ' + decidedIds.length + ' instance' + (decidedIds.length === 1 ? '' : 's') +
          ' · one audit event each',
        false,
        { ids: decidedIds, priorStatus: 'pending' }
      );

      // refresh data
      await reload();
    } catch (err) {
      console.error(err);
      showStatus(
        'Decision failed: ' +
          (err.message || err) +
          (err.body ? '\n' + JSON.stringify(err.body) : ''),
        true
      );
    } finally {
      busy = false;
      updateChrome();
      render();
    }
    return results;
  }

  function selectEligible() {
    allRows.forEach(function (r) {
      if (isDecided(r)) return;
      checked.set(Number(r.id), !isFlagged(r));
    });
    render();
  }

  function selectNonePending() {
    allRows.forEach(function (r) {
      if (!isDecided(r)) checked.set(Number(r.id), false);
    });
    render();
  }

  function selectFlaggedExceptions() {
    // Add flagged pending to selection (for reject-all FP path)
    allRows.forEach(function (r) {
      if (!isDecided(r) && isFlagged(r)) checked.set(Number(r.id), true);
    });
    bandFilter = 'flagged';
    Array.prototype.forEach.call(el.bands.querySelectorAll('.band-tab'), function (b) {
      b.classList.toggle('active', b.getAttribute('data-band') === 'flagged');
    });
    render();
  }

  function visiblePendingRows() {
    return allRows.filter(function (r) {
      return passesBand(r) && !isDecided(r);
    });
  }

  function moveFocus(delta) {
    var rows = visiblePendingRows();
    if (!rows.length) {
      rows = allRows.filter(function (r) {
        return passesBand(r);
      });
    }
    if (!rows.length) return;
    var idx = rows.findIndex(function (r) {
      return Number(r.id) === Number(focusId);
    });
    if (idx < 0) idx = 0;
    else idx = Math.max(0, Math.min(rows.length - 1, idx + delta));
    focusId = Number(rows[idx].id);
    var node = el.body.querySelector('.inst[data-id="' + focusId + '"]');
    if (node) {
      el.body.querySelectorAll('.inst.focus').forEach(function (n) {
        n.classList.remove('focus');
      });
      node.classList.add('focus');
      node.scrollIntoView({ block: 'nearest' });
    }
  }

  function toggleFocusRow() {
    if (focusId == null) {
      moveFocus(0);
    }
    if (focusId == null) return;
    var cur = checked.get(Number(focusId));
    setCheck(focusId, !cur);
    render();
    // restore focus class after re-render
    var node = el.body.querySelector('.inst[data-id="' + focusId + '"]');
    if (node) node.classList.add('focus');
  }

  function wireKeyboard() {
    document.addEventListener('keydown', function (e) {
      var tag = (e.target && e.target.tagName) || '';
      if (tag === 'INPUT' || tag === 'TEXTAREA' || tag === 'SELECT' || e.target.isContentEditable)
        return;
      if (e.metaKey || e.ctrlKey || e.altKey) return;
      var k = e.key;
      if (k === 'Escape') {
        e.preventDefault();
        el.btnClose.click();
        return;
      }
      if (k === 'a' || k === 'A') {
        e.preventDefault();
        decide('accepted');
        return;
      }
      if (k === 'r' || k === 'R') {
        e.preventDefault();
        decide('rejected');
        return;
      }
      if (k === 'x' || k === 'X') {
        e.preventDefault();
        toggleFocusRow();
        return;
      }
      if (k === 'j' || k === 'J') {
        e.preventDefault();
        moveFocus(1);
        return;
      }
      if (k === 'k' || k === 'K') {
        e.preventDefault();
        moveFocus(-1);
        return;
      }
      if (k === 's' || k === 'S') {
        e.preventDefault();
        selectEligible();
        return;
      }
      if (k === 'u' || k === 'U') {
        e.preventDefault();
        void undoLast();
      }
    });
  }

  function sortRows(rows) {
    return rows.slice().sort(function (a, b) {
      var fa = docLabel(a);
      var fb = docLabel(b);
      if (fa !== fb) return fa < fb ? -1 : 1;
      var pa = Number(a.page_no) || 0;
      var pb = Number(b.page_no) || 0;
      if (pa !== pb) return pa - pb;
      return Number(a.id) - Number(b.id);
    });
  }

  async function reload() {
    var rows;
    if (caseId != null) {
      rawRows = await loadCaseSuggestions(caseId);
      rows = filterEntity(rawRows);
    } else {
      rows = await resolveCaseAndLoad();
      rawRows = rows.slice();
    }
    allRows = sortRows(rows);
    inferMeta(allRows);
    if (!entityId) {
      entityText = 'Scoped bulk';
      entityKind = allRows.length
        ? allRows.length + ' suggestions in selection'
        : 'No matching suggestions';
    }
    el.title.textContent = entityText;
    el.kind.textContent = formatKindCase(entityKind, caseNo);
    initChecks(allRows);
    render();
  }

  function wireScope() {
    var globEl = document.getElementById('doc-glob');
    var fromEl = document.getElementById('page-from');
    var toEl = document.getElementById('page-to');
    var applyBtn = document.getElementById('btn-apply-scope');
    if (globEl && docGlob) globEl.value = docGlob;
    if (fromEl && pageFrom != null) fromEl.value = String(pageFrom);
    if (toEl && pageTo != null) toEl.value = String(pageTo);
    function apply() {
      docGlob = globEl ? globEl.value : '';
      pageFrom = fromEl && fromEl.value !== '' ? num(fromEl.value) : null;
      pageTo = toEl && toEl.value !== '' ? num(toEl.value) : null;
      if (rawRows.length) {
        allRows = sortRows(filterEntity(rawRows));
      } else {
        allRows = sortRows(applyScope(allRows));
      }
      initChecks(allRows);
      render();
    }
    if (applyBtn) applyBtn.addEventListener('click', apply);
    if (globEl) {
      globEl.addEventListener('keydown', function (e) {
        if (e.key === 'Enter') {
          e.preventDefault();
          apply();
        }
      });
    }
  }

  async function boot() {
    el.body.innerHTML = '<div class="loading">Loading instances…</div>';
    wireScope();
    try {
      allRows = await resolveCaseAndLoad();
      rawRows = allRows.slice();
      // re-apply entity + scope (resolveCaseAndLoad already filtered entity)
      allRows = sortRows(applyScope(allRows));
      inferMeta(allRows);
      if (!entityId) {
        entityText = docsParam.length
          ? 'Selection · ' + docsParam.length + ' documents'
          : 'Case-wide bulk';
        entityKind = allRows.length + ' suggestions';
      }
      el.title.textContent = entityText;
      el.kind.textContent = formatKindCase(entityKind, caseNo);
      initChecks(allRows);
      render();
    } catch (err) {
      console.error(err);
      el.title.textContent = entityId != null ? 'Entity #' + entityId : 'Bulk review';
      el.kind.textContent = '—';
      el.body.innerHTML =
        '<div class="error">Failed to load suggestions' +
        (err.status ? ' (HTTP ' + err.status + ')' : '') +
        '.<br><code style="font-size:11px">' +
        esc(err.message || String(err)) +
        '</code><br><span style="color:var(--mut);font-size:12px">Expected GET /api/cases/:id/suggestions</span></div>';
      showStatus('Load failed: ' + (err.message || err), true);
    }
  }

  el.body.addEventListener('click', onBodyClick);
  el.body.addEventListener('change', function (e) {
    var t = e.target;
    if (t && t.matches && t.matches('input[type=checkbox][data-id]')) {
      setCheck(t.getAttribute('data-id'), t.checked);
      updateChrome();
    }
  });
  el.bands.addEventListener('click', onBandClick);
  el.btnAccept.addEventListener('click', function () {
    decide('accepted');
  });
  el.btnReject.addEventListener('click', function () {
    decide('rejected');
  });
  el.btnClose.addEventListener('click', function () {
    if (window.history.length > 1) window.history.back();
    else if (caseId != null) window.location.href = '/cases/' + caseId;
    else window.location.href = '/';
  });

  var btnSelElig = document.getElementById('btn-sel-eligible');
  var btnSelNone = document.getElementById('btn-sel-none');
  var btnSelFlag = document.getElementById('btn-sel-flagged');
  if (btnSelElig) btnSelElig.addEventListener('click', selectEligible);
  if (btnSelNone) btnSelNone.addEventListener('click', selectNonePending);
  if (btnSelFlag) btnSelFlag.addEventListener('click', selectFlaggedExceptions);
  var undoBtn = document.getElementById('bulk-undo');
  if (undoBtn) undoBtn.addEventListener('click', function () { void undoLast(); });

  wireKeyboard();

  // expose for console verification
  window.__bulk = {
    getRows: function () {
      return allRows;
    },
    getSelected: selectedRows,
    selectedCount: selectedCount,
    decide: decide,
    undo: undoLast,
    selectEligible: selectEligible,
    reload: reload,
    entityId: function () {
      return entityId;
    },
    caseId: function () {
      return caseId;
    },
    docScope: function () {
      return docScope ? Array.from(docScope) : null;
    },
  };

  boot();
})();
