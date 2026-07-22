# UX Review: Closure Redaction Tool

**To:** Alok Subbarao
**From:** Gemini (acting as Senior Product/UX Designer)
**Date:** July 19, 2026
**Subject:** Concrete UX review and recommendations for the Closure take-home project.

Alok, here is my opinionated review of the design and product thinking for the Closure redaction tool. My goal is to provide concrete, buildable recommendations to guide implementation.

*(Note: The product owner's screenshots were not accessible at the specified paths. This review is based on the detailed design mockups, rationale documents, and the key ideas summarized in the prompt, which provide a clear and sufficient vision for this critique.)*

---

### A) Summary of Core Product Ideas (The PO's Vision)

The provided materials articulate a strong, coherent product vision centered on high-throughput triage. The core ideas are:

*   **Triage, Not Reading:** The fundamental model is an inbox, not a document editor. The user's job is to make rapid decisions on AI suggestions, not to read documents front-to-back. The UI rightly prioritizes the suggestion queue.
*   **Entity-First Decisions:** The unit of decision-making is the *entity* (e.g., "Yasmine Nienow"), not the individual mark on the page. This "decide once, propagate everywhere" model is the primary driver of efficiency.
*   **Confidence Bands, Not Percentages:** Raw percentages are translated into three actionable tiers: **HIGH** (≥90%, safe for bulk review), **REVIEW** (60-89%, needs a look), and **FLAGGED** (<60%, requires mandatory human judgment). This maps directly to the user's mental model and workflow.
*   **Handling False Positives (Don't Redact):** The design provides a two-pronged approach:
    1.  **Why-Card:** An inline callout explains *why* confidence is low (e.g., "Matched PERSON, but context is a STREET NAME").
    2.  **Reject-All Panel:** A single action in the right rail allows the user to reject all similar false positives across the entire case in one click, with the audit reason pre-filled.
*   **Handling False Negatives (Add Missed):** A dedicated `n` + drag mode (`ADD MISSED MODE`) allows the reviewer to manually mark missed text. The critical fork is the scope choice: apply the redaction to "this instance only" or "find & redact all matches in case."
*   **Judge/Adjudication Panel Concept:** While not explicitly named a "judge panel," the concept is clearly implemented through the **FLAGGED** confidence band. Items like "Nienow v. Ohio" (a case citation matching a subject's name) are automatically excluded from bulk operations and require a mandatory, individual human decision before the case can be exported. This *is* the adjudication step.

---

### B) Critique of the Workflow: Coherent but Demands Discipline

The proposed workflow (`Dashboard -> Document -> Review`) is strong, logical, and built for speed. It's a genuinely *working* workflow, not just a collection of screens.

*   **What's Strong:**
    *   **The Funnel:** The flow correctly funnels the user from the macro (case-level stats on the dashboard) to the micro (individual suggestions in the review screen). The "blocked export" banner is an excellent forcing function, guiding the user to the most critical work first (resolving flagged items).
    *   **Information Hierarchy:** The three-panel review screen (`Documents | PDF Canvas | Suggestion Queue`) is the right layout. It provides context at every level without overwhelming the user. The sticky keyboard shortcut legend is a necessary affordance.
    *   **Entity Panel:** The entity list on the dashboard is the app's strategic core. Seeing "9 PENDING" for an entity and being able to jump directly into a bulk review is a massive accelerator.

*   **What's Weak / Potential Friction:**
    *   **Modal Whiplash:** The flow from the main review screen (`02_review.html`) into the bulk review sheet (`05_bulk_review.html`) is a modal overlay. While focused, this jump can be disorienting. A user deciding on the "Yasmine Nienow" entity is pulled out of their document-centric view into a full-screen table. This context switch, while powerful, could slow down a reviewer who prefers to stay oriented within the document.
    *   **Discoverability of Bulk Ops:** The primary entry point for bulk operations is via links in the suggestion queue ("Accept all →", "Bulk →"). This is good, but a reviewer focused on the document canvas might miss it. The power of entity-level decisions needs to be more discoverable.
    *   **Navigational Rigidity:** The design implies a linear path through suggestions (`j`/`k`). What if a reviewer wants to work geographically, clearing all suggestions on the current page before moving to the next? The current queue-based model doesn't explicitly support this workflow, which might be a valid alternative for some users.

---

### C) Specific, Buildable Recommendations

Here are my prioritized recommendations to refine the design for implementation.

**1. Keyboard-First Triage:**
The proposed `j/k/a/r/e` shortcuts are excellent. To make this truly keyboard-first:
*   **Implement Focus Traps:** When a panel or modal is active (e.g., the "Reject-all" panel or the "Add Missed" popover), `Tab` and `Shift+Tab` should cycle focus *only* within that panel. `Esc` must always close the current panel and return focus to the main suggestion queue.
*   **Add Page-Level Shortcuts:** Introduce `p` / `n` (or `PageDown`/`PageUp`) to navigate between *pages* in the document, automatically jumping the suggestion queue to the first suggestion on that page. This supports the "page-at-a-time" workflow.
*   **Confirm with Enter:** Every decision popover or panel (Reject, Add Missed, etc.) should be confirmable with `Enter`. The primary action button must be the default `[type="submit"]`.

**2. Surfacing Confidence:**
The three-band system (HIGH/REVIEW/FLAGGED) is the right model.
*   **Implementation:** Build it exactly as designed. The color-coding (black/amber/red), the filtering chips, and the descriptive text in the queue header are perfect.
*   **Threshold Slider - Why to Avoid:** A slider adds cognitive load for no real benefit. The user doesn't care if confidence is 88% or 89%; they only care if it's "safe" or "needs a look." The semantic bands are superior. Stick with the three-band design.

**3. The Single Best Interaction for Rejecting False Positives:**
The design in `03_reject_false_positive.html` is very strong.
*   **Implementation:**
    1.  On hover/selection of a **FLAGGED** or **REVIEW** item, the **`why-card`** appears anchored to the mark on the page.
    2.  Simultaneously, the right-hand queue is replaced by the **`match-panel`** ("Reject all matching").
    3.  The button in that panel should be explicit: **`Reject all 9 — log as "street name"`**. The audit reason should be automatically inferred from the "why-card" context, but editable.
    4.  Clicking this button or pressing `r` should immediately apply the rejection to all matching items and show the **`undo-toast`**. This is a fast, safe, and transparent flow.

**4. The Single Best Interaction for Adding Missed Redactions:**
The flow in `04_add_missed_redaction.html` is also excellent.
*   **Implementation:**
    1.  User presses `n`, cursor changes to crosshairs, and a persistent **`mode-banner`** appears.
    2.  User drags to select text.
    3.  On mouse-up, the **`add-popover`** appears, anchored to the selection.
    4.  The system should auto-select the most likely category (e.g., "PHONE" for a phone number).
    5.  The "Find & redact all matches" scope option should be the **default**. It should pre-calculate the match count and display it. The user should have to actively choose "This instance only."
    6.  Pressing `Enter` or clicking **`Redact all N`** commits the action. The new items immediately appear in the "Reviewer-added" section of the queue, styled in blue to show provenance.

**5. How a "Judge Panel" Should Appear:**
The current design *already has this* in the form of the **FLAGGED** item workflow. The key is to make this adjudication step more explicit and ergonomic.
*   **Recommendation: The "Adjudication Mode"**
    1.  In the suggestion queue header, add a button: **`Resolve 5 Flagged Items`**.
    2.  Clicking this button enters a special mode:
        *   The queue is filtered to *only* show the 5 flagged items.
        *   The PDF canvas automatically scrolls to the first flagged item.
        *   The `why-card` is **pinned open** on the screen (not just on hover).
        *   The action buttons are simplified to `Keep as Redaction` and `Reject as Not PII`.
    3.  When the user makes a decision, the item is removed from the adjudication queue, and the canvas automatically jumps to the next flagged item.
    4.  This creates a focused, repeatable loop (`see context -> decide -> next`) for only the hardest cases, without the noise of other suggestions. It's a "judge panel" integrated directly into the primary review surface, preventing jarring context switches.
