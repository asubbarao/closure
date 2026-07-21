/**
 * Closure — add-missed mode (false-negative flow)
 * Route: GET /ui/add-missed?doc=<id>&page=<n>
 * Owns drag → PDF-pt convert → search → POST /api/documents/:id/add
 */
(function () {
  'use strict';

  var C = window.Closure;
  var CFG = window.CLOSURE_ADD || {};
  var ACTOR = CFG.actor || C.DEFAULT_ACTOR;
  var escapeHtml = C.escapeHtml;
  var DISPLAY_W = CFG.displayW || 680;

  var params = new URLSearchParams(window.location.search);
  // Entity ids are opaque strings (uuid document ids, case="24-001001") — never Number()/parseInt.
  var docId = String(params.get('doc') || params.get('id') || CFG.docId || '').trim();
  var pageNo = parseInt(params.get('page') || '1', 10);
  if (!isFinite(pageNo) || pageNo < 1) pageNo = 1;
  var bootCaseId = String(params.get('case') || CFG.caseId || '').trim() || null;

  var state = {
    docId: docId,
    pageNo: pageNo,
    caseId: bootCaseId,
    caseNo: '',
    filename: '',
    pageCount: 1,
    widthPt: 612,
    heightPt: 792,
    scale: DISPLAY_W / 612,
    words: [],
    suggestions: [],
    manualAdds: [],
    kind: null,
    scope: 'one',
    boxPx: null,   // {x0,y0,x1,y1} in display px
    boxPt: null,   // {x0,y0,x1,y1} in PDF points
    matchCount: 0,
    exactCount: 0,
    fuzzyCount: 0,
    otherPages: 0,
    otherDocs: 0,
    searchBusy: false,
    searchTimer: null,
    dragging: false,
    dragOrigin: null,
    lastSearchQ: '',
    lastAddResponse: null
  };

  var el = {
    crumbCase: document.getElementById('crumb-case'),
    crumbDoc: document.getElementById('crumb-doc'),
    progressLabel: document.getElementById('progress-label'),
    progressMeter: document.getElementById('progress-meter'),
    auditLink: document.getElementById('audit-link'),
    exitReview: document.getElementById('exit-review'),
    exitBtn: document.getElementById('exit-btn'),
    pageLabel: document.getElementById('page-label'),
    marksLabel: document.getElementById('marks-label'),
    pgPrev: document.getElementById('pg-prev'),
    pgNext: document.getElementById('pg-next'),
    pdfPage: document.getElementById('pdf-page'),
    pdfBg: document.getElementById('pdf-bg'),
    marksLayer: document.getElementById('marks-layer'),
    dragSelect: document.getElementById('drag-select'),
    popover: document.getElementById('add-popover'),
    textInput: document.getElementById('text-input'),
    catGrid: document.getElementById('cat-grid'),
    scopeOne: document.getElementById('scope-one'),
    scopeAll: document.getElementById('scope-all'),
    scopeOneSub: document.getElementById('scope-one-sub'),
    scopeAllSub: document.getElementById('scope-all-sub'),
    scopeCount: document.getElementById('scope-count'),
    btnCancel: document.getElementById('btn-cancel'),
    btnAdd: document.getElementById('btn-add'),
    auditActor: document.getElementById('audit-actor'),
    hintText: document.getElementById('hint-text'),
    hintKind: document.getElementById('hint-kind'),
    hintAction: document.getElementById('hint-action'),
    coordLine: document.getElementById('coord-line'),
    pendCount: document.getElementById('pend-count'),
    manualCount: document.getElementById('manual-count'),
    manualList: document.getElementById('manual-list'),
    suggList: document.getElementById('sugg-list'),
    toast: document.getElementById('toast'),
    actorLabel: document.getElementById('actor-label')
  };

  function $(sel, root) { return (root || document).querySelector(sel); }

  var lastAddIds = [];

  function toast(msg, kind, opts) {
    var msgEl = document.getElementById('toast-msg');
    var undoBtn = document.getElementById('toast-undo');
    if (msgEl) msgEl.textContent = msg;
    else el.toast.textContent = msg;
    el.toast.className = 'status-toast show' + (kind ? ' ' + kind : '');
    if (undoBtn) {
      var showUndo = opts && opts.undo;
      undoBtn.hidden = !showUndo;
      undoBtn.onclick = showUndo
        ? function () {
            void opts.undo();
          }
        : null;
    }
    clearTimeout(toast._t);
    toast._t = setTimeout(function () {
      el.toast.className = 'status-toast';
      if (undoBtn) undoBtn.hidden = true;
    }, kind === 'err' ? 8000 : opts && opts.ms ? opts.ms : 5200);
  }

  async function undoLastAdd() {
    if (!lastAddIds.length) {
      toast('Nothing to undo', 'err');
      return;
    }
    var ids = lastAddIds.slice();
    lastAddIds = [];
    for (var i = 0; i < ids.length; i++) {
      try {
        await C.postSuggestionDecision(ids[i], {
          status: 'pending',
          actor: ACTOR,
          reason: 'undo add-missed'
        });
      } catch (e) { /* best-effort */ }
    }
    toast('Restored to pending — reviewer-added mark cleared');
    state.manualAdds = [];
    var sug = await loadSuggestions();
    if (sug) {
      state.suggestions = sug;
      renderQueue();
      renderMarks();
    }
  }

  function reviewUrl(d, p) {
    d = d || state.docId;
    p = p || state.pageNo;
    if (p <= 1) return '/documents/' + d;
    return '/documents/' + d + '/pages/' + p;
  }

  function addMissedUrl(d, p) {
    return '/ui/add-missed?doc=' + (d || state.docId) + '&page=' + (p || state.pageNo);
  }

  function exitToReview() {
    window.location.href = reviewUrl();
  }

  // ── bootstrap: scrape review HTML for doc meta (no extra SQL routes needed) ──

  function parseReviewHtml(html) {
    var doc = new DOMParser().parseFromString(html, 'text/html');
    var meta = {};

    var caseA = doc.querySelector('.crumb .case');
    if (caseA) {
      meta.caseNo = (caseA.textContent || '').replace(/^CASE\s+/i, '').trim();
      // Case ids are opaque strings (e.g. "24-001001"), not integers.
      var hm = (caseA.getAttribute('href') || '').match(/\/cases\/([^/?#]+)/);
      if (hm) meta.caseId = decodeURIComponent(hm[1]);
    }
    // Prefer data-case-id / data-doc-id on body when present (string ids).
    var body = doc.body;
    if (body) {
      var dCase = body.getAttribute('data-case-id');
      var dDoc = body.getAttribute('data-doc-id');
      if (dCase) meta.caseId = String(dCase).trim();
      if (dDoc) meta.docId = String(dDoc).trim();
    }

    var docSpan = doc.querySelector('.crumb .doc');
    if (docSpan) {
      meta.filename = (docSpan.textContent || '').replace(/\.pdf$/i, '').trim();
    }

    var img = doc.querySelector('.pdf-page img.pdf-bg, .pdf-page img, img.pdf-bg');
    if (img) {
      var src = img.getAttribute('src') || '';
      // tera may HTML-escape slashes as &#x2F;
      src = src.replace(/&#x2F;/gi, '/').replace(/&amp;/g, '&');
      meta.pngHref = src;
      var pm = src.match(/\/pages\/([^/]+)\/p(\d+)\.png/);
      if (pm) {
        meta.filename = meta.filename || pm[1];
      }
    }

    var pageLabel = doc.querySelector('.page-nav span');
    // Prefer "PAGE N / M"
    var spans = doc.querySelectorAll('.page-nav span');
    for (var i = 0; i < spans.length; i++) {
      var tm = (spans[i].textContent || '').match(/PAGE\s+(\d+)\s*\/\s*(\d+)/i);
      if (tm) {
        meta.pageNo = parseInt(tm[1], 10);
        meta.pageCount = parseInt(tm[2], 10);
        break;
      }
    }

    var hint = '';
    var hintBar = doc.querySelector('.hint-bar, .coord-proof');
    var bodyText = doc.body ? doc.body.textContent : '';
    var sm = bodyText.match(/scale\s+([0-9.]+)\s*·\s*page\s+([0-9.]+)\s*[×x]\s*([0-9.]+)/i);
    if (sm) {
      meta.scale = parseFloat(sm[1]);
      meta.widthPt = parseFloat(sm[2]);
      meta.heightPt = parseFloat(sm[3]);
    }

    var pageEl = doc.querySelector('.pdf-page');
    if (pageEl) {
      var st = pageEl.getAttribute('style') || '';
      var wh = st.match(/width:\s*([0-9.]+)px/);
      var hh = st.match(/height:\s*([0-9.]+)px/);
      if (wh) meta.displayW = parseFloat(wh[1]);
      if (hh) meta.displayH = parseFloat(hh[1]);
    }

    // Collect existing marks on this page from rendered HTML
    meta.marks = [];
    doc.querySelectorAll('.pdf-page .mark').forEach(function (m) {
      var style = m.getAttribute('style') || '';
      function px(re) {
        var x = style.match(re);
        return x ? parseFloat(x[1]) : 0;
      }
      var cls = m.className || '';
      var status = 'pending';
      if (/\baccepted\b/.test(cls)) status = 'accepted';
      else if (/\brejected\b/.test(cls)) status = 'rejected';
      else if (/\bflagged\b/.test(cls)) status = 'flagged';
      meta.marks.push({
        left_px: px(/left:\s*([0-9.]+)px/),
        top_px: px(/top:\s*([0-9.]+)px/),
        width: px(/width:\s*([0-9.]+)px/),
        height: px(/height:\s*([0-9.]+)px/),
        status: status,
        text: m.getAttribute('title') || ''
      });
    });

    // Words from word layer (full page, better than LIMIT 50 API)
    meta.words = [];
    doc.querySelectorAll('.pdf-page .word, .word-layer .word').forEach(function (w) {
      var style = w.getAttribute('style') || '';
      function px(re) {
        var x = style.match(re);
        return x ? parseFloat(x[1]) : null;
      }
      var title = w.getAttribute('title') || '';
      var tm2 = title.match(/pt\s*\(([-\d.]+),\s*([-\d.]+)\)–\(([-\d.]+),\s*([-\d.]+)\)/);
      var left = px(/left:\s*([0-9.]+)px/);
      var top = px(/top:\s*([0-9.]+)px/);
      var width = px(/width:\s*([0-9.]+)px/);
      var height = px(/height:\s*([0-9.]+)px/);
      meta.words.push({
        word: (w.textContent || '').trim(),
        x0: tm2 ? parseFloat(tm2[1]) : (left != null ? left / (meta.scale || state.scale) : 0),
        y0: tm2 ? parseFloat(tm2[2]) : (top != null ? top / (meta.scale || state.scale) : 0),
        x1: tm2 ? parseFloat(tm2[3]) : ((left != null && width != null) ? (left + width) / (meta.scale || state.scale) : 0),
        y1: tm2 ? parseFloat(tm2[4]) : ((top != null && height != null) ? (top + height) / (meta.scale || state.scale) : 0),
        left_px: left,
        top_px: top,
        width: width,
        height: height
      });
    });

    // Progress "N of M"
    var pw = doc.querySelector('.pw span, .progress-wrap span');
    if (pw) {
      var pr = (pw.textContent || '').match(/(\d+)\s+of\s+(\d+)/);
      if (pr) {
        meta.resolved = parseInt(pr[1], 10);
        meta.total = parseInt(pr[2], 10);
      }
    }

    return meta;
  }

  async function fetchJson(url, opts) {
    return C.fetchJson(url, opts);
  }

    async function loadWordsApi() {
    // Prefer page-scoped route; fall back to page-1 route
    var urls = [
      '/api/documents/' + state.docId + '/pages/' + state.pageNo + '/words',
      '/api/documents/' + state.docId + '/words'
    ];
    for (var i = 0; i < urls.length; i++) {
      try {
        var r = await fetchJson(urls[i]);
        if (r.ok && Array.isArray(r.data) && r.data.length) {
          return r.data.map(function (w) {
            return {
              word: w.word,
              x0: +w.x0, y0: +w.y0, x1: +w.x1, y1: +w.y1
            };
          });
        }
      } catch (e) { /* try next */ }
    }
    return [];
  }

  async function loadSuggestions() {
    var urls = [
      '/api/documents/' + state.docId + '/suggestions',
      '/api/documents/' + state.docId + '/pages/' + state.pageNo + '/suggestions'
    ];
    for (var i = 0; i < urls.length; i++) {
      try {
        var r = await fetchJson(urls[i]);
        if (r.ok && r.data) {
          var rows = Array.isArray(r.data) ? r.data : (r.data.suggestions || r.data.rows || []);
          if (Array.isArray(rows)) return rows;
        }
      } catch (e) { /* */ }
    }
    return null;
  }

  function applyMeta(meta) {
    if (meta.caseId != null && String(meta.caseId).trim() !== '') {
      state.caseId = String(meta.caseId).trim();
    }
    if (meta.docId != null && String(meta.docId).trim() !== '') {
      state.docId = String(meta.docId).trim();
    }
    if (meta.caseNo) state.caseNo = meta.caseNo;
    if (meta.filename) state.filename = meta.filename;
    if (meta.pageCount) state.pageCount = meta.pageCount;
    if (meta.widthPt) state.widthPt = meta.widthPt;
    if (meta.heightPt) state.heightPt = meta.heightPt;
    if (meta.scale) state.scale = meta.scale;
    else state.scale = DISPLAY_W / state.widthPt;
    if (meta.words && meta.words.length) state.words = meta.words;
    if (meta.marks) state.htmlMarks = meta.marks;

    var displayH = meta.displayH || Math.round(state.heightPt * state.scale * 10) / 10;
    el.pdfPage.style.width = DISPLAY_W + 'px';
    el.pdfPage.style.height = displayH + 'px';

    var png = meta.pngHref || ('/pages/' + state.filename + '/p' + state.pageNo + '.png');
    el.pdfBg.src = png;
    el.pdfBg.onerror = function () {
      el.pdfBg.style.display = 'none';
      el.marksLabel.textContent = 'PNG missing for ' + state.filename + ' — drag still works in pt space';
      el.pdfPage.style.background = '#fafafa';
    };
    el.pdfBg.onload = function () {
      el.pdfBg.style.display = 'block';
    };

    el.crumbCase.textContent = 'CASE ' + (state.caseNo || state.caseId || '…');
    el.crumbCase.href = state.caseId ? '/cases/' + state.caseId : '#';
    el.crumbDoc.textContent = state.filename ? state.filename + '.pdf' : 'document ' + state.docId;
    el.auditLink.href = state.caseId ? '/cases/' + state.caseId + '/audit' : '#';
    el.exitReview.href = reviewUrl();
    el.actorLabel.textContent = ACTOR;
    el.auditActor.textContent = ACTOR;

    el.pageLabel.textContent = 'PAGE ' + state.pageNo + ' / ' + state.pageCount;
    el.pgPrev.href = addMissedUrl(state.docId, Math.max(1, state.pageNo - 1));
    el.pgNext.href = addMissedUrl(state.docId, Math.min(state.pageCount, state.pageNo + 1));
    el.pgPrev.classList.toggle('is-disabled', state.pageNo <= 1);
    el.pgNext.classList.toggle('is-disabled', state.pageNo >= state.pageCount);
    el.scopeOneSub.textContent = 'Redact just this one occurrence on p.' + state.pageNo;

    if (meta.resolved != null && meta.total != null) {
      el.progressLabel.textContent = meta.resolved + ' of ' + meta.total;
      var pct = meta.total ? Math.round(100 * meta.resolved / meta.total) : 0;
      el.progressMeter.style.width = pct + '%';
    }

    updateCoordLine();
  }

  function updateCoordLine() {
    var box = '—';
    if (state.boxPt) {
      box = state.boxPt.x0.toFixed(1) + ',' + state.boxPt.y0.toFixed(1) +
        '–' + state.boxPt.x1.toFixed(1) + ',' + state.boxPt.y1.toFixed(1);
    }
    el.coordLine.textContent =
      'scale ' + state.scale.toFixed(4) +
      ' · page ' + state.widthPt + '×' + state.heightPt + ' pt' +
      ' · box pt ' + box +
      (state.filename ? ' · /pages/' + state.filename + '/p' + state.pageNo + '.png' : '');
  }

  function renderMarks() {
    var html = '';
    var marks = [];

    if (state.htmlMarks && state.htmlMarks.length) {
      marks = state.htmlMarks;
    } else if (state.suggestions && state.suggestions.length) {
      marks = state.suggestions
        .filter(function (s) { return +s.page_no === state.pageNo || s.page_no == null; })
        .map(function (s) {
          return {
            left_px: (+s.x0) * state.scale,
            top_px: (+s.y0) * state.scale,
            width: ((+s.x1) - (+s.x0)) * state.scale,
            height: ((+s.y1) - (+s.y0)) * state.scale,
            status: s.status || 'pending',
            text: s.text || ''
          };
        });
    }

    // overlay local manual adds for this page
    state.manualAdds.forEach(function (m) {
      if (m.page_no !== state.pageNo) return;
      marks.push({
        left_px: m.x0 * state.scale,
        top_px: m.y0 * state.scale,
        width: (m.x1 - m.x0) * state.scale,
        height: (m.y1 - m.y0) * state.scale,
        status: 'manual',
        text: m.text
      });
    });

    marks.forEach(function (m) {
      var st = m.status || 'pending';
      html += '<div class="mark ' + escapeHtml(st) + '" style="left:' + m.left_px +
        'px;top:' + m.top_px + 'px;width:' + m.width + 'px;height:' + m.height +
        'px" title="' + escapeHtml(m.text || '') + '"></div>';
    });
    el.marksLayer.innerHTML = html;
    el.marksLabel.textContent = marks.length + ' mark' + (marks.length === 1 ? '' : 's') + ' on this page · drag to add';
  }

  function renderQueue() {
    var suggs = state.suggestions || [];
    var pageSuggs = suggs.filter(function (s) {
      return s.page_no == null || +s.page_no === state.pageNo;
    });
    var pending = suggs.filter(function (s) {
      return !s.status || s.status === 'pending';
    }).length;
    el.pendCount.textContent = pending + ' pending';

    if (!suggs.length && !state.suggestionsLoaded) {
      el.suggList.innerHTML = '<div class="empty-q">No suggestion API yet — page canvas still works for manual add.</div>';
    } else if (!pageSuggs.length) {
      el.suggList.innerHTML = '<div class="empty-q">No AI suggestions on this page.</div>';
    } else {
      el.suggList.innerHTML = pageSuggs.slice(0, 40).map(function (s) {
        var st = s.status || 'pending';
        return '<div class="sugg">' +
          '<span class="sw ' + escapeHtml(st) + '"></span>' +
          '<div class="sugg-text"><div class="val">' + escapeHtml(s.text) + '</div>' +
          '<div class="ctx">' + escapeHtml(s.context || s.kind || '') + '</div></div>' +
          '<div class="sugg-meta"><div class="conf">' + escapeHtml(s.confidence != null ? s.confidence : '') +
          '</div><div class="pg-ref">p.' + escapeHtml(s.page_no != null ? s.page_no : state.pageNo) + '</div></div></div>';
      }).join('');
    }

    el.manualCount.textContent = String(state.manualAdds.length);
    if (!state.manualAdds.length) {
      el.manualList.innerHTML =
        '<div class="missed-row" id="manual-empty"><div class="mr-text">' +
        '<div class="mr-meta">Drag on the page to add a missed redaction</div></div></div>';
    } else {
      el.manualList.innerHTML = state.manualAdds.slice().reverse().map(function (m) {
        return '<div class="missed-row">' +
          '<div class="mr-sw done"></div>' +
          '<div class="mr-text"><div class="mr-val">' + escapeHtml(m.text) + '</div>' +
          '<div class="mr-meta">' + escapeHtml(m.kind) + ' · p.' + m.page_no +
          (m.scope === 'all' ? ' · case-wide' : '') +
          ' — ' + escapeHtml(ACTOR) + '</div></div>' +
          '<span class="mr-badge ok">ADDED ✓</span></div>';
      }).join('');
    }
  }

  // ── geometry ──

  function pagePoint(evt) {
    var rect = el.pdfPage.getBoundingClientRect();
    var x = evt.clientX - rect.left;
    var y = evt.clientY - rect.top;
    x = Math.max(0, Math.min(rect.width, x));
    y = Math.max(0, Math.min(rect.height, y));
    return { x: x, y: y };
  }

  function normalizeBox(a, b) {
    return {
      x0: Math.min(a.x, b.x),
      y0: Math.min(a.y, b.y),
      x1: Math.max(a.x, b.x),
      y1: Math.max(a.y, b.y)
    };
  }

  function pxToPt(boxPx) {
    // Inverse of contract transform: pt = px / scale
    var s = state.scale || (DISPLAY_W / state.widthPt);
    return {
      x0: boxPx.x0 / s,
      y0: boxPx.y0 / s,
      x1: boxPx.x1 / s,
      y1: boxPx.y1 / s
    };
  }

  function showDrag(box) {
    el.dragSelect.style.display = 'block';
    el.dragSelect.style.left = box.x0 + 'px';
    el.dragSelect.style.top = box.y0 + 'px';
    el.dragSelect.style.width = Math.max(1, box.x1 - box.x0) + 'px';
    el.dragSelect.style.height = Math.max(1, box.y1 - box.y0) + 'px';
  }

  function hideDrag() {
    el.dragSelect.style.display = 'none';
  }

  function wordsInBox(boxPt) {
    var hits = [];
    state.words.forEach(function (w) {
      var cx = (w.x0 + w.x1) / 2;
      var cy = (w.y0 + w.y1) / 2;
      if (cx >= boxPt.x0 && cx <= boxPt.x1 && cy >= boxPt.y0 && cy <= boxPt.y1) {
        hits.push(w);
      }
    });
    hits.sort(function (a, b) {
      if (Math.abs(a.y0 - b.y0) > 2) return a.y0 - b.y0;
      return a.x0 - b.x0;
    });
    return hits;
  }

  function textFromBox(boxPt) {
    return wordsInBox(boxPt).map(function (w) { return w.word; }).join(' ').trim();
  }

  // ── popover ──

  function setKind(kind) {
    state.kind = kind;
    el.catGrid.querySelectorAll('.cat-btn').forEach(function (b) {
      b.classList.toggle('selected', b.getAttribute('data-kind') === kind);
    });
    el.hintKind.textContent = kind || '—';
    updateConfirmBtn();
  }

  function setScope(scope) {
    state.scope = scope;
    el.scopeOne.classList.toggle('selected', scope === 'one');
    el.scopeAll.classList.toggle('selected', scope === 'all');
    var r1 = el.scopeOne.querySelector('input');
    var r2 = el.scopeAll.querySelector('input');
    if (r1) r1.checked = scope === 'one';
    if (r2) r2.checked = scope === 'all';
    updateConfirmBtn();
  }

  function updateConfirmBtn() {
    var text = (el.textInput.value || '').trim();
    var ready = !!(text && state.kind && state.boxPt);
    el.btnAdd.disabled = !ready;
    if (!ready) {
      el.btnAdd.textContent = state.scope === 'all' ? 'Redact all…' : 'Add this redaction';
      el.hintAction.textContent = !state.boxPt ? 'Draw a box, then confirm'
        : !text ? 'Enter the text under the box'
        : !state.kind ? 'Pick a category'
        : 'Ready';
      return;
    }
    if (state.scope === 'all') {
      var n = Math.max(state.matchCount || 0, 1);
      el.btnAdd.textContent = 'Redact all ' + n + ' ⏎';
      el.hintAction.textContent = 'Will mark ' + n + ' instance' + (n === 1 ? '' : 's') + ' · confirm or ⏎';
    } else {
      el.btnAdd.textContent = 'Add this redaction';
      el.hintAction.textContent = 'Will mark 1 instance · confirm or ⏎';
    }
    el.hintText.textContent = text || '—';
  }

  function positionPopover(boxPx) {
    var pageW = el.pdfPage.clientWidth;
    var pageH = el.pdfPage.clientHeight;
    var popW = 312;
    var left = boxPx.x0;
    if (left + popW > pageW - 8) left = Math.max(8, pageW - popW - 8);
    var top = boxPx.y1 + 8;
    // measure after open
    el.popover.style.left = left + 'px';
    el.popover.style.top = top + 'px';
    el.popover.classList.add('open');
    // if overflows bottom, place above
    requestAnimationFrame(function () {
      var ph = el.popover.offsetHeight || 320;
      if (top + ph > pageH - 8 && boxPx.y0 - ph - 8 > 0) {
        el.popover.style.top = Math.max(8, boxPx.y0 - ph - 8) + 'px';
      }
    });
  }

  function openDialog(boxPx, boxPt, prefill) {
    state.boxPx = boxPx;
    state.boxPt = boxPt;
    showDrag(boxPx);
    el.textInput.value = prefill || '';
    el.hintText.textContent = prefill || '—';
    state.matchCount = 0;
    state.exactCount = 0;
    state.fuzzyCount = 0;
    state.otherPages = 0;
    state.otherDocs = 0;
    el.scopeCount.textContent = '—';
    el.scopeAllSub.textContent = prefill
      ? 'Searching…'
      : 'Type text above to search the case';
    if (!state.kind) setKind(guessKind(prefill));
    else setKind(state.kind);
    setScope(state.scope || 'one');
    positionPopover(boxPx);
    updateCoordLine();
    updateConfirmBtn();
    setTimeout(function () {
      el.textInput.focus();
      el.textInput.select();
    }, 0);
    if (prefill) scheduleSearch();
  }

  function closeDialog(keepDrag) {
    el.popover.classList.remove('open');
    if (!keepDrag) {
      hideDrag();
      state.boxPx = null;
      state.boxPt = null;
    }
    updateCoordLine();
  }

  function guessKind(text) {
    if (!text) return 'OTHER';
    var t = text.trim();
    if (/\d{3}[-\s]?\d{2}[-\s]?\d{4}/.test(t)) return 'SSN';
    if (/\(?\d{3}\)?[-\s.]?\d{3}[-\s.]?\d{4}/.test(t)) return 'PHONE';
    if (/\d{1,2}\/\d{1,2}\/\d{2,4}/.test(t)) return 'DOB';
    if (/\d+\s+\w+/.test(t) && /(st|ave|lane|dr|road|blvd|street)/i.test(t)) return 'ADDRESS';
    if (/^[A-Z][a-z]+(\s+[A-Z][a-z'.-]+)+$/.test(t)) return 'PERSON';
    return 'OTHER';
  }

  // ── search ──

  function scheduleSearch() {
    clearTimeout(state.searchTimer);
    state.searchTimer = setTimeout(runSearch, 220);
  }

  function normalizeSearchPayload(data) {
    // Contract: {matches:[...], count, exact_count, fuzzy_count}
    // Each match may carry match_kind ('exact'|'fuzzy') + score.
    // quackapi may also return a bare array of match rows
    function deriveCounts(matches, exactHint, fuzzyHint, totalHint) {
      var exact = exactHint != null && isFinite(+exactHint) ? +exactHint : null;
      var fuzzy = fuzzyHint != null && isFinite(+fuzzyHint) ? +fuzzyHint : null;
      if (exact == null || fuzzy == null) {
        var ex = 0;
        var fu = 0;
        var sawKind = false;
        (matches || []).forEach(function (m) {
          var k = m && (m.match_kind || m.matchKind);
          if (k === 'exact') { ex++; sawKind = true; }
          else if (k === 'fuzzy' || k === 'similar') { fu++; sawKind = true; }
        });
        if (sawKind) {
          if (exact == null) exact = ex;
          if (fuzzy == null) fuzzy = fu;
        }
      }
      var count = totalHint != null && isFinite(+totalHint)
        ? +totalHint
        : (matches ? matches.length : 0);
      if (exact == null && fuzzy == null) {
        exact = count;
        fuzzy = 0;
      } else {
        if (exact == null) exact = 0;
        if (fuzzy == null) fuzzy = 0;
        if (totalHint == null) count = exact + fuzzy;
      }
      return { matches: matches || [], count: count, exact_count: exact, fuzzy_count: fuzzy };
    }

    if (!data) return { matches: [], count: 0, exact_count: 0, fuzzy_count: 0 };
    if (Array.isArray(data)) {
      // could be [{matches, count}] single wrapper or flat match rows
      if (data.length === 1 && data[0] && (data[0].matches || data[0].count != null)) {
        var w = data[0];
        var m = w.matches;
        if (typeof m === 'string') {
          try { m = JSON.parse(m); } catch (e) { m = []; }
        }
        return deriveCounts(
          Array.isArray(m) ? m : [],
          w.exact_count != null ? w.exact_count : w.exactCount,
          w.fuzzy_count != null ? w.fuzzy_count : w.fuzzyCount,
          w.count
        );
      }
      return deriveCounts(data, null, null, data.length);
    }
    if (typeof data === 'object') {
      var matches = data.matches;
      if (typeof matches === 'string') {
        try { matches = JSON.parse(matches); } catch (e) { matches = []; }
      }
      if (!Array.isArray(matches)) matches = [];
      return deriveCounts(
        matches,
        data.exact_count != null ? data.exact_count : data.exactCount,
        data.fuzzy_count != null ? data.fuzzy_count : data.fuzzyCount,
        data.count
      );
    }
    return { matches: [], count: 0, exact_count: 0, fuzzy_count: 0 };
  }

  /** Local fallback: count phrase hits in loaded page words (reading order). */
  function localPageMatchCount(q) {
    if (!q || !state.words.length) return 0;
    var norm = function (s) { return String(s).replace(/\s+/g, ' ').trim().toLowerCase(); };
    var needle = norm(q);
    if (!needle) return 0;
    // Join words in reading order with spaces; also try token-window matches
    var sorted = state.words.slice().sort(function (a, b) {
      if (Math.abs(a.y0 - b.y0) > 2) return a.y0 - b.y0;
      return a.x0 - b.x0;
    });
    var joined = sorted.map(function (w) { return w.word; }).join(' ');
    var hay = norm(joined);
    var count = 0;
    var from = 0;
    while (from <= hay.length) {
      var i = hay.indexOf(needle, from);
      if (i < 0) break;
      count++;
      from = i + Math.max(needle.length, 1);
    }
    // single-token exact equals
    if (count === 0 && needle.indexOf(' ') < 0) {
      sorted.forEach(function (w) {
        if (norm(w.word) === needle) count++;
      });
    }
    return count;
  }

  function applyMatchStats(count, matches, sourceLabel, exactCount, fuzzyCount) {
    matches = matches || [];
    var exact = exactCount != null ? +exactCount : count;
    var fuzzy = fuzzyCount != null ? +fuzzyCount : 0;
    if (!isFinite(exact)) exact = 0;
    if (!isFinite(fuzzy)) fuzzy = 0;
    var total = count != null && isFinite(+count) ? +count : (exact + fuzzy);
    state.matchCount = total;
    state.exactCount = exact;
    state.fuzzyCount = fuzzy;
    var pages = {};
    var docs = {};
    matches.forEach(function (m) {
      var d = m.document_id != null ? m.document_id : m.documentId;
      var p = m.page_no != null ? m.page_no : m.pageNo;
      if (d != null) docs[String(d)] = true;
      if (p != null) {
        var key = String(d) + ':' + String(p);
        // Compare document ids as opaque strings; page_no stays numeric.
        if (!(String(d) === String(state.docId) && +p === state.pageNo)) pages[key] = true;
      }
    });
    var otherPageN = Object.keys(pages).length;
    var docN = Object.keys(docs).length || (total > 0 ? 1 : 0);
    // Count chip: always "N exact · M similar" (search upgrade contract)
    el.scopeCount.textContent = exact + ' exact · ' + fuzzy + ' similar';
    if (total === 0) {
      el.scopeAllSub.textContent = sourceLabel
        ? ('No other matches in this case. (' + sourceLabel + ')')
        : 'No other matches in this case.';
    } else if (otherPageN > 0) {
      el.scopeAllSub.textContent =
        exact + ' exact · ' + fuzzy + ' similar on ' + otherPageN +
        ' other page' + (otherPageN === 1 ? '' : 's') +
        ' across ' + Math.max(docN, 1) + ' doc' + (docN === 1 ? '' : 's');
    } else if (total === 1) {
      el.scopeAllSub.textContent = '1 match · this page only' +
        (sourceLabel ? ' · ' + sourceLabel : '');
    } else {
      el.scopeAllSub.textContent =
        exact + ' exact · ' + fuzzy + ' similar · this page / nearby' +
        (sourceLabel ? ' · ' + sourceLabel : '');
    }
  }

  async function runSearch() {
    var q = (el.textInput.value || '').trim();
    el.hintText.textContent = q || '—';
    updateConfirmBtn();
    if (!q) {
      el.scopeCount.textContent = '—';
      el.scopeAllSub.textContent = 'Type text above to search the case';
      state.matchCount = 0;
      state.exactCount = 0;
      state.fuzzyCount = 0;
      return;
    }
    if (!state.caseId) {
      el.scopeCount.textContent = '?';
      el.scopeAllSub.textContent = 'Case id unknown — search needs case=';
      return;
    }
    state.searchBusy = true;
    el.scopeAllSub.textContent = 'Searching…';
    try {
      var url = '/api/search?q=' + encodeURIComponent(q) + '&case=' + encodeURIComponent(state.caseId);
      var r = await fetchJson(url);
      if (!r.ok) {
        // Fallback: local page word scan so the count chip still populates
        var local = localPageMatchCount(q);
        state.lastSearchQ = q;
        applyMatchStats(local, local > 0 ? [{
          document_id: state.docId,
          page_no: state.pageNo
        }] : [], r.status === 404
          ? 'local page scan · API pending'
          : ('HTTP ' + r.status + ' · local scan'), local, 0);
        updateConfirmBtn();
        return;
      }
      var parsed = normalizeSearchPayload(r.data);
      var matches = parsed.matches || [];
      var count = parsed.count != null ? parsed.count : matches.length;
      state.lastSearchQ = q;
      applyMatchStats(count, matches, null, parsed.exact_count, parsed.fuzzy_count);
    } catch (err) {
      var local2 = localPageMatchCount(q);
      applyMatchStats(local2, local2 > 0 ? [{
        document_id: state.docId, page_no: state.pageNo
      }] : [], 'search error · local scan', local2, 0);
    } finally {
      state.searchBusy = false;
      updateConfirmBtn();
    }
  }

  // ── confirm / POST add ──

  async function confirmAdd() {
    var text = (el.textInput.value || '').trim();
    if (!text || !state.kind || !state.boxPt) {
      updateConfirmBtn();
      return;
    }
    if (!state.docId) {
      toast('ADD failed · missing document id', 'err');
      updateConfirmBtn();
      return;
    }
    var box = state.boxPt;
    // Round to 4dp for stable geometry; server accepts DOUBLE (P0-4).
    // Must be finite numbers — empty/"undefined" query values → HTTP 422 type_error on x*.
    var x0 = round4(box.x0);
    var y0 = round4(box.y0);
    var x1 = round4(box.x1);
    var y1 = round4(box.y1);
    if (![x0, y0, x1, y1].every(function (n) { return typeof n === 'number' && isFinite(n); })) {
      toast('ADD failed · invalid coords (need finite PDF points)', 'err');
      updateConfirmBtn();
      return;
    }
    var pageInt = parseInt(state.pageNo, 10);
    if (!isFinite(pageInt) || pageInt < 1) pageInt = 1;
    var qs = new URLSearchParams({
      page: String(pageInt),
      x0: String(x0),
      y0: String(y0),
      x1: String(x1),
      y1: String(y1),
      text: text,
      kind: state.kind,
      scope: state.scope === 'all' ? 'all' : 'one',
      actor: ACTOR,
      reason: 'missed by AI'
    });
    // Opaque string document id (uuid) — do not Number()-coerce.
    var url = '/api/documents/' + encodeURIComponent(state.docId) + '/add?' + qs.toString();
    el.btnAdd.disabled = true;
    el.btnAdd.textContent = 'Saving…';
    try {
      // JSON body required by some quackapi binds; coords stay in query.
      var r = await fetchJson(url, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: '{}'
      });
      state.lastAddResponse = r;
      var bodyStr = typeof r.data === 'string' ? r.data : JSON.stringify(r.data, null, 0);
      // P0-4: NEVER paint success on 4xx — UI reflects SERVER result only.
      if (!r.ok) {
        toast('ADD failed · POST ' + r.status + ' · ' +
          (bodyStr || r.raw || '').slice(0, 280), 'err');
        updateConfirmBtn();
        return;
      }
      var serverMark = {
        text: text,
        kind: state.kind,
        page_no: pageInt,
        x0: x0, y0: y0, x1: x1, y1: y1,
        scope: state.scope,
        response: r.data,
        http: r.status,
        url: url
      };
      // Extract suggestion id(s) if server returns them for undo — keep as strings (uuid).
      lastAddIds = [];
      try {
        var payload = r.data;
        if (Array.isArray(payload) && payload[0]) payload = payload[0];
        var sid =
          payload &&
          (payload.id != null
            ? payload.id
            : payload.suggestion_id != null
              ? payload.suggestion_id
              : payload.suggestionId);
        if (sid != null && String(sid).trim() !== '' && String(sid) !== 'NaN') {
          lastAddIds = [String(sid)];
        }
      } catch (e) { /* */ }

      var scopeNote =
        state.scope === 'all' && state.matchCount > 1
          ? ' · scope=all (' + state.matchCount + ' matches requested)'
          : '';
      toast('Added missed — "' + text + '"' + scopeNote, 'ok', {
        undo: lastAddIds.length ? undoLastAdd : null,
        ms: 8000
      });
      state.manualAdds.push(serverMark);
      closeDialog(false);
      renderMarks();
      renderQueue();
      // refresh suggestions if API exists (server is source of truth)
      var sug = await loadSuggestions();
      if (sug) {
        state.suggestions = sug;
        state.suggestionsLoaded = true;
        // if we didn't get an id from POST, try match newest added by text
        if (!lastAddIds.length) {
          var added = sug.filter(function (s) {
            return (
              String(s.kind || '').toLowerCase() === 'added' ||
              String(s.status) === 'accepted'
            ) && String(s.text) === text;
          });
          if (added.length) {
            var aid = added[added.length - 1].id;
            if (aid != null && String(aid).trim() !== '' && String(aid) !== 'NaN') {
              lastAddIds = [String(aid)];
            }
          }
        }
        renderQueue();
        renderMarks();
      }
    } catch (err) {
      toast('ADD error: ' + (err && err.message ? err.message : err), 'err');
      updateConfirmBtn();
    }
  }

  function round4(n) {
    var v = Math.round(Number(n) * 10000) / 10000;
    return isFinite(v) ? v : NaN;
  }

  // ── pointer events ──

  function onPointerDown(evt) {
    if (evt.button != null && evt.button !== 0) return;
    // ignore interactions inside popover
    if (el.popover.contains(evt.target)) return;
    closeDialog(false);
    state.dragging = true;
    state.dragOrigin = pagePoint(evt);
    showDrag({ x0: state.dragOrigin.x, y0: state.dragOrigin.y, x1: state.dragOrigin.x, y1: state.dragOrigin.y });
    evt.preventDefault();
  }

  function onPointerMove(evt) {
    if (!state.dragging || !state.dragOrigin) return;
    var p = pagePoint(evt);
    showDrag(normalizeBox(state.dragOrigin, p));
  }

  function onPointerUp(evt) {
    if (!state.dragging || !state.dragOrigin) return;
    state.dragging = false;
    var p = pagePoint(evt);
    var boxPx = normalizeBox(state.dragOrigin, p);
    state.dragOrigin = null;
    var w = boxPx.x1 - boxPx.x0;
    var h = boxPx.y1 - boxPx.y0;
    if (w < 4 && h < 4) {
      hideDrag();
      return;
    }
    // minimum readable mark height
    if (h < 6) {
      boxPx.y1 = boxPx.y0 + 10;
    }
    var boxPt = pxToPt(boxPx);
    var prefill = textFromBox(boxPt);
    openDialog(boxPx, boxPt, prefill);
  }

  // ── wire UI ──

  function wire() {
    el.pdfPage.addEventListener('mousedown', onPointerDown);
    window.addEventListener('mousemove', onPointerMove);
    window.addEventListener('mouseup', onPointerUp);

    el.exitBtn.addEventListener('click', exitToReview);
    el.btnCancel.addEventListener('click', function () { closeDialog(false); });
    el.btnAdd.addEventListener('click', function () { confirmAdd(); });

    var histBtn = document.getElementById('btn-history');
    if (histBtn) {
      histBtn.addEventListener('click', function () {
        if (!C.openHistory()) toast('History not available on this page', 'err');
      });
    }

    el.catGrid.addEventListener('click', function (evt) {
      var btn = evt.target.closest('.cat-btn');
      if (!btn) return;
      setKind(btn.getAttribute('data-kind'));
    });

    el.scopeOne.addEventListener('click', function () { setScope('one'); });
    el.scopeAll.addEventListener('click', function () { setScope('all'); });

    el.textInput.addEventListener('input', function () {
      scheduleSearch();
      updateConfirmBtn();
    });
    el.textInput.addEventListener('keydown', function (evt) {
      if (evt.key === 'Enter') {
        evt.preventDefault();
        confirmAdd();
      }
    });

    document.addEventListener('keydown', function (evt) {
      var tag = (evt.target && evt.target.tagName) || '';
      if (evt.key === 'Escape') {
        if (el.popover.classList.contains('open') || state.boxPt) {
          closeDialog(false);
          evt.preventDefault();
          return;
        }
        exitToReview();
      }
      if (evt.key === 'Enter' && el.popover.classList.contains('open') && !evt.target.matches('input,textarea')) {
        confirmAdd();
      }
      if ((evt.key === 'u' || evt.key === 'U') && !C.isEditableTarget(evt.target)) {
        if (lastAddIds.length) {
          evt.preventDefault();
          void undoLastAdd();
        }
      }
    });
  }

  async function boot() {
    wire();
    document.title = 'Closure — Add missed · doc ' + state.docId + ' p.' + state.pageNo;

    // 1) scrape review page for meta + words + marks
    try {
      var res = await fetch(reviewUrl(state.docId, state.pageNo));
      if (res.ok) {
        var html = await res.text();
        var meta = parseReviewHtml(html);
        applyMeta(meta);
      } else {
        toast('Could not load document ' + state.docId + ' (HTTP ' + res.status + ')', 'err');
        applyMeta({ filename: 'document_' + state.docId, widthPt: 612, heightPt: 792, pageCount: 1 });
      }
    } catch (err) {
      toast('Bootstrap failed: ' + err.message, 'err');
      applyMeta({ filename: 'document_' + state.docId, widthPt: 612, heightPt: 792, pageCount: 1 });
    }

    // 2) words API as supplement (if scrape missed them)
    if (!state.words.length) {
      try {
        var apiWords = await loadWordsApi();
        if (apiWords.length) state.words = apiWords;
      } catch (e) { /* */ }
    }

    // 3) suggestions
    try {
      var sug = await loadSuggestions();
      state.suggestionsLoaded = true;
      if (sug) state.suggestions = sug;
    } catch (e) {
      state.suggestionsLoaded = true;
    }

    renderMarks();
    renderQueue();
    updateCoordLine();

    // Expose for manual verify / console
    window.__addMissed = {
      state: state,
      pxToPt: pxToPt,
      runSearch: runSearch,
      confirmAdd: confirmAdd,
      openDialog: openDialog
    };
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', boot);
  } else {
    boot();
  }
})();
