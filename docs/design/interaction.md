# Reading Interaction Design

This document defines current Settings, reading and document-tab behavior. See [validation status](../validation.md) for tested scope and [requirements](../requirements.md) for product requirements.

Model management follows the [configuration contract](model-settings.md): translation direction is a Settings preference, while the active model is shared with the toolbar.

The [reading refinement contract](#2026-11-07-reading-refinement-proposal) supersedes earlier width, paragraph-label and highlight defaults.

## Reading surface

Use one reading window with document tabs and a compact native toolbar. The main surface is the text, without a permanent library sidebar, chat panel, or model conversation. Keep the layout switch and translation action directly accessible, plus an entry to Settings. Add documents using the tab bar's plus button. Place a native **Active Model** menu immediately to the left of the translation action. Show the selected instance name and a chevron, with a checkmark on the current item. Use the instance metadata to disambiguate names. Give the control an accessible label and value, and preserve the full name in the menu if the toolbar truncates it. With an empty list, offer **Add Model in Settings…**. Use the same committed selection as Settings. Show the actual job model and effort separately in document metadata. Explain that Resume and Retry use the retained model when it differs from the toolbar selection.

## Document tabs

Each tab represents an independent long-text document that may itself contain many paragraphs. Tabs are not individual paragraphs of one translation.

The confirmed scope includes adding, switching, closing, and translating multiple documents. The implementation baseline is:

- A new tab starts with an input view. Switching tabs preserves its draft, source, translation, its recorded language direction, progress, reading layout, and pinned correspondence. Native reading-position restoration remains required.
- Translation continues in background tabs, whose labels show compact progress or failure state. The [native design](technical-design.md) bounds concurrency at four model operations globally and two translation batches per document session. These are internal limits.
- Each job owns its document ID, source revision, and request generation. Results from a cancelled request or closed tab cannot update another document, even if the title is reused.
- A job snapshots its direction and provider/model/profile/effort/endpoint configuration. Toolbar and Settings choices apply to new jobs and confirmed Retranslate. Resume retains that snapshot; endpoint changes or deleted credentials can block future requests without affecting completed text. Portable documents require an explicit local configuration binding before model calls, as specified in [model configuration](model-settings.md#runtime-snapshots-credentials-and-portable-documents).
- Closing a running tab offers Keep Tab or Stop and Close, followed by Save/Discard/Cancel when needed. The [native design](technical-design.md) specifies dirty-state and quit behavior; the [document format](document-format.md) defines explicit local persistence. Closing an unchanged fixture needs no prompt.
- Closing a tab does not delete a source file or affect another tab. Closing the final tab shows an empty reading window with a New translation action.

## Reading layouts

The default layout is **Side by side**: original on the left, translation on the right. Align paragraph starts, and link scrolling by paragraph identity; translation length must not determine an unrelated scroll position. Keep the column divider quiet and paragraph numbering secondary.

**Paragraphs** presents one continuous column: original paragraph, its translation, then the next pair. Use a single language-side key above the reading surface, distinct readable foreground colors, spacing and a quiet translation-side rule, without repeating labels before each pair. Switching layouts preserves the active paragraph and pinned correspondence without making another translation request.

## Correspondence

| Action or condition | Behavior |
| --- | --- |
| Hover over an available phrase or sentence mapping | Softly highlight the corresponding source and translation; clear it on pointer exit |
| Hover where only paragraph mapping is available | Highlight the paragraph pair |
| Click a mapped phrase or select it | Pin the correspondence and show the phrase pair in a compact bottom strip |
| Select text without a reliable phrase match | Identify the larger corresponding sentence or paragraph, label the fallback, and avoid implying an exact word match |
| Clear or press Escape | Remove pinned correspondence and return to ordinary reading |
| Hover with a pinned match | Keep the pinned match stable until cleared or replaced |
| Hover over an offscreen counterpart | Do not jump the document; native implementation may offer an explicit reveal action |

Native text selection uses the system selection color. Correspondence uses the selected appearance-adaptive preset (Amber by default), with an underline or edge marker and a text label when pinned. Meaning must remain clear without color alone. Hover uses available mappings and does not issue a model request on every pointer movement. Additional selection analysis must show its pending state separately from translation.

## Input and task lifecycle

The tab bar's plus button opens a new document with an original-text input view. Choose **Translation Direction** (`翻译方向`) in Settings → General, with **Automatic** (`自动识别`) as the initial and migration default, plus **Chinese → English** and **English → Chinese**. Use the existing local recognizer for Automatic. On ambiguous input, keep the draft or existing translation and offer **Open Settings** or **Cancel** before any model call. Settings changes apply on Save and leave open document text and results intact.

A fresh Translate or explicit Retranslate captures the committed direction and active model together when the action starts. Validate the direction before committing a replacement. Successful replacement updates the document's requested and resolved direction under the existing revision and result-invalidation rules. Retry, Resume and phrase analysis keep the direction and model of the original job. Opening or saving a document without a new translation preserves its recorded direction. See [model workflow](model-workflow.md#source-planning-in-swift).

Translation displays completed paragraphs as they arrive. Cancel stops remaining work and retains completed paragraphs; resume retries unfinished work. A partial failure identifies the unfinished portion while leaving completed text readable. Editing the original creates a new revision and invalidates affected results, as required by the product's integrity rules.

## Settings

Provide a dedicated native Settings window. Organize low-frequency preferences into three small sections:

| Section | Initial controls |
| --- | --- |
| General | Interface language: English (initial default) or Simplified Chinese |
| General | Appearance: System (initial default), Light, or Dark |
| General | Translation Direction, with Automatic as the initial default |
| General | Don't ask to save on close, initially off |
| Models | Active Model picker, followed by configured model instances and Add/Edit/Delete |
| Reading | Reading Width, Correspondence Color with preview, font family, reading text size, and line spacing |

Interface language only changes application chrome; it does not change a document's source language, translation direction, or existing text. Project documentation, code, and comments still default to English. Localized UI strings are product data, not a change to that policy.

Appearance defaults to System and supports explicit Light/Dark overrides. Save applies it across reading and Settings windows. Use native semantic colors, preserve selection/reading position, and respond to system appearance changes while System is selected. The [native design](technical-design.md#settings-and-appearance) owns implementation details.

Reading preferences apply across open tabs. Layout remains a frequent, per-document control on the reading surface. Save applies the entire settings draft; Cancel discards it. Keep preferences small and avoid adding unrequested prompt editors, agent controls, or infrastructure configuration.

The [model configuration design](model-settings.md) owns vendor-scoped choices, instance names, per-instance credentials, active selection and migration. Switching the active model updates the selection immediately from the toolbar. Existing jobs keep their recorded binding, and replacement still requires Retranslate confirmation. Keep exactly one localized app-menu Settings entry and Command-comma shortcut; the Settings window title follows the same language.

## Typography and native presentation

Default to the system UI font and appropriate Chinese system fallback. Use the native design's 17-point initial reading size and adjustable line spacing; evaluate the supported size range in both layouts. Offer reading-size adjustments in Settings, readable column widths, light/dark appearances, and reduced-motion support. Offer the approved system and serif reading typefaces.

The icon direction is [C — Parallel text](icons/README.md), selected by the owner. Use the icon's correspondence motif sparingly; the reading window should remain visually quiet. Final icon sizing and platform masking need separate validation.

Use native window controls, menus, focus behavior, and text selection. Shortcuts are New tab (Command-T), Close tab (Command-W), Translate (Command-Return), layouts (Command-1/2), Settings (Command-comma), and Clear/Dismiss (Escape).

## About Bipara

Keep the native About panel. The screenshot's `Version 0.1.0 (1)` is conventional on macOS. The app's Xcode target sets `MARKETING_VERSION = 0.1.0` and `CURRENT_PROJECT_VERSION = 1`, generating `CFBundleShortVersionString` and `CFBundleVersion` respectively. The parentheses are presentation. Increment the build number for each distributed build and change the release version when issuing a new version. [Apple distribution guidance](https://developer.apple.com/documentation/xcode/preparing-your-app-for-distribution).

## Implementation references

Use the [development plan](../development-plan.md), [model workflow](model-workflow.md), [prompts](../../prompts/README.md) and [test plan](../testing.md).

## Validation boundary

The Settings/tab concept was approved by the owner before native implementation. Concept review establishes interaction intent; native selection, scrolling, focus, accessibility, appearance, revision changes, and cancellation require actual macOS evidence. The [native integration report](../validation.md) records the exercised cases and incomplete gates. Real-provider behavior, account access, latency and translation quality remain separate checks.

## 2026-11-07 reading refinement proposal

This section replaces repeated paragraph labels, earlier width caps and warm-only highlights. Prompt, document-identity and global Active Model contracts remain unchanged. The anchor is retained for link compatibility.

Implemented behavior, actual checks and remaining gates are recorded in the [reading refinement validation report](../validation.md).

### Clean reading and unfinished translation

Remove the Original/Translation label before every paragraph pair. Keep column headings in Side by side. In Paragraphs, show a single source/translation key above the reading surface. Each pair keeps the same order, with an 8-point source-to-translation gap and a 24-point gap before the next pair; use a restrained leading rule for the translated passage so color is not the only cue. VoiceOver still identifies each side.

Text tokens on the semantic text background: Light source `#202124`, translation `#245C78`; Dark source `#E4E4E7`, translation `#ABCBD9`. Keep equal font size/weight and normal reading contrast; do not make source text a disabled or low-opacity label. Resolve colors at display time, including Increase Contrast, and validate them against every highlight preset. Native color and contrast evidence belongs in the validation report.

Do not put `Not translated yet`, `Queued`, skeleton text, or a spinner into every untranslated paragraph. Show the job status once in the bottom strip. Leave the pending translation area empty; in Paragraphs, reserve only a quiet minimum gap rather than a full empty translation block. Side by side retains source/target paragraph alignment and its necessary layout space. If no translation exists, show one nonselectable pane-level message, `Translation will appear here`, only while idle; hide it once queued/running. Never insert it into document text or exports.

| Job condition | Bottom strip | Reading surface |
| --- | --- | --- |
| Queued/running | Spinner, `Translating 38/142 · 24s` | Completed text appears progressively; unfinished areas stay empty |
| Paused | `Paused · 38/142 · 24s`, with Resume in the existing toolbar | Keep completed text; indicate unfinished paragraph ranges with a non-text gutter mark |
| Failed | `38/142 · 24s · Translation stopped`, with Retry in the toolbar and a concise error detail | Keep completed text and mark affected unfinished ranges; do not imply all remaining work failed |
| Completed | Checkmark, `142/142 · 1m 23s` | No completion banner or repeated labels in the text |

Counts are completed translation units out of nonblank units, matching current scheduling; expose that meaning in the accessible label/tooltip. Use the actual job snapshot's model for attribution, e.g. `GLM Flash · 142/142 · 1m 23s`. Put full vendor/model/effort and elapsed-time meaning in a tooltip/accessibility detail rather than a long visible status line. At narrow widths collapse attribution to an accessible info control before hiding progress/time. Keep correspondence-analysis progress independent and allow the existing match actions to fit without clipping.

Pending/gutter/status elements have no selectable model span. Partial assembly remains paragraph-atomic; never fabricate translation for uncommitted units. Copy, selection analysis and export retain their own canonical-text rules, including explicit missing-content markers in partial bilingual export. Capture paragraph/side anchors before progressive insertion and restore the same logical reading position after layout. A missing target uses the source paragraph anchor until real target text exists.

### Wider reading area

Add `Reading Width` under Settings → Reading: `Standard`, `Wide` (default), `Window`. These are global reading preferences; the selected reading layout stays per document. Use point measurements from the live content area, not screenshot pixels. For each column/pane, subtract the reading inset before applying the cap.

| Width | Side by side, maximum per column | Paragraphs, maximum single column |
| --- | --- | --- |
| Standard | 720pt | 800pt |
| Wide | 960pt | 1080pt |
| Window | Available pane width minus insets | Available pane width minus insets |

Use 32-point horizontal insets per pane, reduced to 24 below 1100-point window width. Center capped text within its pane and align each column heading to its actual text edge. Keep font size and line spacing unchanged; reduce excess margins rather than shrinking text. At a sufficiently wide window the Wide caps allow 50% more line width than the current 640/720-point caps. At narrow sizes available space remains the limit. Preserve the chosen layout, equal column division, paragraph start alignment, selection, pin and anchor when width/font/appearance changes. Do not measure paragraphs on hover or on elapsed-time ticks.

### Default titles and elapsed time

Create immediately visible, session-unique `Untitled 1`, `Untitled 2`, etc.; do not use punctuation-only titles such as `---`. Keep an increasing workspace-local counter, without a new durable identifier or a model call. A meaningful imported `.txt` filename can supply the title. For pasted text, derive the title on Apply/Translate from the first source line containing a Unicode letter or number, skipping Markdown separators, code fences and punctuation-only lines. Strip a simple leading Markdown heading/list marker for the title only; cap an automatic title at 48 grapheme clusters within the existing codec limit. Keep the full title in a tab tooltip/accessibility label. If no meaningful line exists, retain its numbered title. Existing `.bipara` titles and user-chosen titles stay unchanged. Title changes never mutate source bytes, document/session IDs or an existing on-disk filename. Use the title as the suggested Save filename.

Elapsed time belongs to the tab's current translation job, not the active toolbar model or a global stopwatch. Use one monotonic clock interval while queued/running, starting when a validated job enters queued state, including dispatch wait, provider requests and automatic retry/backoff. Do not sum concurrent batch durations. Stop on completed, paused or failed. Resume/Retry of the retained job adds another active interval; user pause/failed idle time and selection analysis are excluded. Fresh Translate/Retranslate resets time. Cancelled preflight or Retranslate confirmation does not start/reset it. Display whole seconds (`9s`), minutes/seconds (`1m 23s`) or hours/minutes (`1h 04m`), with a one-second UI refresh that cannot replan or remeasure text.

Timing is session-local. Do not infer old durations from unit completion timestamps, persist clock instants in `.bipara`, or change document schema for this feature. A reopened file has no historical elapsed-time display; if resumed, the timer covers activity since that open and its tooltip says so. This limitation must remain visible in the implementation report.

### Model scope and concurrent tabs

Current source confirms one committed, app-wide Active Model ID. It is the default for fresh Translate and confirmed Retranslate in any tab. Each job independently freezes provider, model, effort, profile and endpoint binding when it starts. Switching the picker from A to B does not migrate a running A job; another tab can start with B. Returning to the A tab still shows the global B picker and A in job attribution. Resume, Retry and selection analysis retain A. Replacing a completed translation with B still requires Retranslate confirmation. A portable reopened document requires an explicit local binding before further model calls.

Clarify the picker help text: `Default for new translations. Existing jobs keep their model.` Keep actual job attribution visible. Editing an A record's model/effort does not rewrite its existing snapshot. Deleting that record, changing its provider/Base URL or removing its credential can block later A dispatches; an already dispatched call keeps its captured configuration. Replacing a credential affects later dispatches through the retained binding. Recommend separate named A/B configurations for simultaneous work. Per-tab active pickers would be a separate product choice and are not part of this handoff. Offline concurrent-model fixtures and live provider tests establish separate evidence layers.

### Correspondence colors

Settings → Reading adds `Correspondence Color`: Blue, Teal, Amber (default), Purple. Show a live local bilingual preview and an appearance-aware swatch for each preset; no arbitrary RGB editor is needed for this request. Save/Cancel uses the existing Settings draft. This preference applies across tabs and is not exported in documents.

The owner's 2026-11-07 color follow-up adopts Amber as the shared default for both appearances: a pale amber fill in Light and a muted dark amber fill in Dark. Its warm hue separates correspondence from the cool translation text and native text selection while retaining the restrained reading layout. Fresh preferences and older records without an explicit color use this default; an explicitly saved preset remains respected. Runtime helpers and the compiled default color asset use the same paired tokens.

| Preset | Light background | Dark background |
| --- | --- | --- |
| Blue | `#DCEAF7` | `#28455C` |
| Teal | `#D9EEE9` | `#254A43` |
| Amber | `#F6E8C8` | `#514327` |
| Purple | `#EAE2F5` | `#443651` |

These are the adopted paired tokens. Keep source/translation foreground colors legible on all preset fills, and verify at least 4.5:1 actual reading-text contrast. Retain a thin correspondence underline and the existing match-type/pin explanation. Preserve macOS native text-selection colors and selected text foreground; the app preference changes only correspondence, including hover/selected-counterpart/pin highlights. Source text color may be neutralized locally if necessary to pass contrast, without changing the native selected range. Increase Contrast must strengthen the non-color cue. Re-resolve and repaint when appearance or the preset changes, even if highlighted ranges are identical; do not clear the pin, lose selection, move the viewport or issue a model request.

### Close preference and English menus

Settings → General adds `Don't ask to save on close`, initially unchecked, with helper text: `Unsaved changes will be discarded when you close a tab or quit. Saved files are not changed.` Enabling it is an explicit opt-in to discard, not autosave or session recovery. Save applies the preference; Cancel discards the draft. Apply it consistently to tab close, Command-W, main-window close and Command-Q. When enabled, skip only the dirty-document Save/Discard/Cancel stage and follow Discard. Keep `Stop translation and close?` for queued/running work, and retain the Settings-draft close review. Normal Save failures, source-replacement confirmation, provider consent and existing-file overwrite handling keep their own behavior. Turning the preference off restores ordinary prompts. Closing a tab cannot cancel another job or delete/overwrite a saved file.

The screenshot's Chinese custom Settings/Translation commands alongside English system commands are consistent with app chrome following its saved Simplified Chinese preference while system-supplied menus follow macOS localization. The current code defaults fresh preferences to English, but does not reset an existing saved language. For the requested English interface, select Settings → General → Interface Language → English and Save. Verify that `Settings…`, `Translation`, their window titles, toolbar labels and app-owned dialogs are English, with one Settings item and Command-comma shortcut. Retain Chinese as an explicit supported choice under R13/R18; do not hardcode only two menu labels to English while leaving the rest of app chrome Chinese. Do not reset an existing saved language as part of a reading-preference upgrade.

### Implementation scope and handoff

Read [native design](technical-design.md), [model settings](model-settings.md), [document format](document-format.md) and [acceptance cases](../testing.md#2026-11-07-reading-refinement-acceptance). Preferences remain optional on read with explicit defaults; preserve model configurations, credentials, language, typography and corrupt/newer-record protection. No portable duration field is added.

Changes stay within reading presentation, session timing/titles, Settings, close policy and their fixtures. Use existing state/bridge boundaries. Exercise deterministic offline fixtures and actual native rendering in both appearances and layouts; a design preview is not native UI acceptance. Record actual application build, UI and packaged-runtime results separately from real-provider evidence.
