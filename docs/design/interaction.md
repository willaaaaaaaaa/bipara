# Reading Interaction Design

This document defines Settings, reading and document-tab behavior, including Markdown. See [validation status](../validation.md) for tested scope and [requirements](../requirements.md) for product requirements.

Model management follows the [configuration contract](model-settings.md): translation direction is a Settings preference, while the active model is shared with the toolbar.

The [reading details](#reading-details) specify progress presentation, width, titles, timing and highlight colors.

## Reading surface

Use one reading window with document tabs and a compact native toolbar. The main surface is the text, without a permanent library sidebar, chat panel, or model conversation. Keep the layout switch and translation action directly accessible, plus an entry to Settings. Add documents using the tab bar's plus button. Leave a small gap after the reading controls, then place the native **Active Model** menu immediately to the left of the translation action. Show the selected instance name and a chevron, with a checkmark on the current item. Use the instance metadata to disambiguate names. Give the control an accessible label and value, and preserve the full name in the menu if the toolbar truncates it. With an empty list, offer **Add Model in Settings…**. Use the same committed selection as Settings. Show the actual job model and effort separately in document metadata. Explain that Resume and Retry use the retained model when it differs from the toolbar selection.

## Document tabs

Each tab represents an independent long-text document that may itself contain many paragraphs. Tabs are not individual paragraphs of one translation.

The confirmed scope includes adding, switching, closing, and translating multiple documents. The implementation baseline is:

- The reading window has one New Translation plus button next to the tabs. It stays visible when tabs overflow. Opening, creating or switching to a tab scrolls its label into view. A new tab starts with an input view. Switching tabs preserves its draft, source, translation, its recorded language direction, progress, and reading layout. Native reading-position restoration remains required.
- Translation continues in background tabs. A failure marks the owning tab without interrupting the front document. Select the tab and open its failure details to inspect the error. The [native design](technical-design.md) bounds concurrency at four model operations globally and two translation batches per document session. These are internal limits.
- Each job owns its document ID, source revision, and request generation. Results from a cancelled request or closed tab cannot update another document, even if the title is reused.
- A job snapshots its direction and provider/model/profile/effort/endpoint configuration. Toolbar and Settings choices apply to new jobs and confirmed Retranslate. Resume retains that snapshot; endpoint changes or deleted credentials can block future requests without affecting completed text. Portable documents require an explicit local configuration binding before model calls, as specified in [model configuration](model-settings.md#runtime-snapshots-credentials-and-portable-documents).
- Closing a running tab offers Keep Tab or Stop and Close, followed by Save/Discard/Cancel when needed. The [native design](technical-design.md) specifies dirty-state and quit behavior; the [document format](document-format.md) defines explicit local persistence. Closing an unchanged fixture needs no prompt.
- Closing a tab does not delete a source file or affect another tab. Closing the final tab shows an empty reading window with a New translation action.

## Reading layouts

The default layout is **Side by side**: original on the left, translation on the right. Align paragraph starts, and link scrolling by paragraph identity; translation length must not determine an unrelated scroll position. Keep the column divider quiet and paragraph numbering secondary.

**Paragraphs** presents one continuous column: original paragraph, its translation, then the next pair. Use a single language-side key above the reading surface, distinct readable foreground colors, spacing and a quiet translation-side rule, without repeating labels before each pair. Switching layouts preserves the active paragraph without making another translation request.

### Translation reader

Choose **Translation Reader** (译文主栏) in the current tab’s layout control, in the View menu, or with Command-3. The layout icons depict side-by-side columns, stacked sections and a single page. Each segment has its own localized tooltip and accessible name: **Side by side**, **Paragraphs** (**Sections** for Markdown) or **Translation Reader**. New documents start side by side. The reader is a temporary view choice remembered while switching between open tabs. Saving and reopening a file restores its last paired layout at the saved reading position. The themes in Settings apply to all three views. Markdown’s Preview/Source choice stays independent.

Show translated passages in source order in one selectable, centered column, using the single-column reading width and the user’s typography. Preserve a stable line of text as earlier or later results arrive. While idle with no results, show one nonselectable placeholder. Once queued or running, the footer supplies the status. Newly committed passages appear in place with one short fade; Reduce Motion makes them appear immediately. Keep existing passages steady across redraws, theme changes and tab switches. With partial results, show completed passages and the current task status. An unfinished passage never appears as a translated result. A supported literal-only Markdown document can show its preserved content. For an unreadable Markdown plan, use the existing literal fallback and disable Translation Reader.

Use native text selection and copying in Translation Reader. To compare with the source, switch to a paired layout at the current reading position.

### Copy when ready

Place **Copy Translation** (复制译文) in the active tab’s existing bottom status area, within keyboard reach at any scroll position. It appears in all three layouts for a complete, copyable translation, including one reopened from disk. At minimum width, keep the labeled Copy action and the current task status visible. Collapse model details to keep the action and progress visible. A background tab becoming ready never takes focus or changes the active tab’s footer.

| Result at the active tab | Footer and clipboard |
| --- | --- |
| Draft, waiting for the first result, translating, paused or failed with unfinished work | Keep the existing task status and controls. Reading partial results never writes to the clipboard. |
| Complete translated result | Show **Copy Translation**. A click or keyboard activation copies the complete plain translation or reconstructed Markdown through the same command as the document menu. The selected range, current scroll position and Markdown display mode do not affect that output. |
| Copy succeeds | Show **Copied** in place briefly, announce success once, then restore the action. Preserve reading position and keyboard focus. The document’s progress, save state and elapsed time retain their meaning. |
| Copy fails or its request becomes stale | Report a genuine failure locally and keep the action available for retry when eligible. Silently discard superseded requests. Show success only for an actual current clipboard write. |

Keep the document menu’s handling of literal-only Markdown and unavailable plans. Full and explicit partial exports retain their existing File-menu behavior. The completion footer requires actual translated prose and does not celebrate an empty or literal-only result. Native Command-C still copies the focused selection. The three themes may change the footer material and transition. All use the same labels, location and actions, honor Reduce Motion and Reduce Transparency, and reserve footer space so readiness or feedback does not move the document.

## Input and task lifecycle

The tab bar's plus button opens a new document with an original-text input view. Choose **Translation Direction** (`翻译方向`) in Settings → General, with **Automatic** (`自动识别`) as the initial and migration default, plus **Chinese → English** and **English → Chinese**. Use the existing local recognizer for Automatic. On ambiguous input, keep the draft or existing translation and offer **Open Settings** or **Cancel** before any model call. Settings changes apply on Save and leave open document text and results intact.

A fresh Translate or explicit Retranslate captures the committed direction and active model together when the action starts. Validate the direction before committing a replacement. Successful replacement updates the document's requested and resolved direction under the existing revision and result-invalidation rules. Retry and Resume keep the direction and model of the original job. Opening or saving a document without a new translation preserves its recorded direction. See [model workflow](model-workflow.md#source-planning-in-swift). The toolbar offers Retry for failed tasks and Retranslate for completed tasks. The document menu offers Retranslate for failed tasks, giving readers a way to replace the whole result. In Simplified Chinese, both whole-document copy entries use **复制译文**.

Translation displays completed paragraphs as they arrive. Cancel stops remaining work and retains completed paragraphs; resume retries unfinished work. A partial failure identifies the unfinished portion while leaving completed text readable. Editing the original creates a new revision and invalidates affected results, as required by the product's integrity rules.

## Settings

The document-format control belongs to each document, as specified in [Markdown reading](#markdown-reading); it is separate from the global translation-language direction below.

Provide a dedicated native Settings window. Organize low-frequency preferences into three small sections:

| Section | Initial controls |
| --- | --- |
| General | Interface language: English (initial default) or Simplified Chinese |
| General | Appearance: System (initial default), Light, or Dark |
| General | Theme: Dynamic Capsule (default), Smoked Glass, or Gradient Frame |
| General | Translation Direction, with Automatic as the initial default |
| General | Discard unsaved changes when closing documents, initially off |
| Models | Active Model picker, followed by configured model instances and Add/Edit/Delete |
| Reading | Reading Width, font family, reading text size, and line spacing |

Interface language only changes application chrome; it does not change a document's source language, translation direction, or existing text. Project documentation, code, and comments still default to English. Localized UI strings are product data, not a change to that policy.

Appearance defaults to System and supports explicit Light/Dark overrides. Save applies it across reading and Settings windows. Use native semantic colors, preserve selection/reading position, and respond to system appearance changes while System is selected. The [native design](technical-design.md#settings-and-appearance) owns implementation details.

Theme changes the reading workspace across all document tabs. Dynamic Capsule uses a compact capsule for job status and copy controls. Smoked Glass uses a tinted material around the reading surface. Gradient Frame gives each document a stable color treatment around its text. All three share the same text colors, native selection, task controls, and document layouts. Honor Reduce Motion for status transitions and Reduce Transparency for translucent materials. A preferences record saved before themes existed opens with Dynamic Capsule and retains its other settings.

Reading preferences apply across open tabs. Layout remains a frequent, per-document control on the reading surface. Save applies the entire settings draft; Cancel discards it. Keep preferences small and avoid adding unrequested prompt editors, agent controls, or infrastructure configuration.

The [model configuration design](model-settings.md) owns the six-field custom editor, instance names, per-instance credentials, active selection and migration. Switching the active model updates the selection immediately from the toolbar. Existing jobs keep their recorded binding, and replacement still requires Retranslate confirmation. Keep exactly one localized app-menu Settings entry and Command-comma shortcut; the Settings window title follows the same language.

## Typography and native presentation

Document text defaults to Menlo at 12 points with native Chinese fallback (PingFang SC on the supported local system), normal weight, no optional ligatures and an 18-point baseline grid. Apply the same typography to the original and translation, plain-text reading, both Markdown modes and the source editor. Settings offers Monospaced, System and Serif, a 12–28-point size range, and adjustable line spacing. Existing saved typography remains unchanged until explicitly edited; fresh preferences use the editor defaults. Retain native system fonts for interface controls, readable column widths, light/dark appearances and reduced-motion support. Typography does not import an editor color theme: keep the existing source/translation palette and a neutral semantic text background across the main workspace, including the input screen. The source editor retains native semantic text colors for existing, typed and pasted content, including after typography or appearance changes.

The [app icon](icons/README.md) represents parallel text. Use the icon's parallel-text motif sparingly; the reading window should remain visually quiet. Final icon sizing and platform masking need separate validation.

Use native window controls, menus, focus behavior, and text selection. Shortcuts are New tab (Command-T), Close tab (Command-W), Translate (Command-Return), layouts (Command-1/2/3), Settings (Command-comma), and Clear/Dismiss (Escape).

Native text controls expose names in the selected interface language, including after a live language change. Side by side identifies Original text and Translation separately. Paragraphs identifies the combined view as Original and translation and explains that each original paragraph precedes its translation. Keep these names and hints in accessibility metadata; do not insert labels into document text, native selection, copied content or exports. The original-text editor follows the same interface-language setting without changing an in-progress composition.

The reading-size slider has its own localized name and retains native numeric values and adjustment actions. Exclude the adjacent visual size readout from accessibility to avoid duplicate or stale announcements.

## About Bipara

Keep the native About panel. Display the release version and build number, for example `Version 0.1.0 (1)`. `Config/Version.xcconfig` supplies `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION`, generating `CFBundleShortVersionString` and `CFBundleVersion` respectively. Increment the build number for each distributed build and change the release version when issuing a new version. [Apple distribution guidance](https://developer.apple.com/documentation/xcode/preparing-your-app-for-distribution).

## Implementation references

Use the [development plan](../development-plan.md), [model workflow](model-workflow.md), [prompts](../../prompts/README.md) and [test plan](../testing.md).

## Markdown reading

These rules extend R24–R28 and supersede paragraph-only presentation only for documents resolved as Markdown. Plain-text documents retain their existing layouts and behavior. The format detector and parser contract live in [native design](technical-design.md#markdown-structure-and-rendering).

### Paste, detect and override

The normal path is New Translation → paste text → local detection → Translate → rendered bilingual reading. Paste consumes the explicit clipboard text once; there is no clipboard watcher, filename requirement, AI classification, additional permission dialog or separate detection step. The editor remains a native plain-text source editor. Format detection updates a compact status/control, not the editable text or caret. Apply can open the rendered source reader before translation, without a model call; pasting alone never unexpectedly replaces the editor or moves its caret.

| Control | Values and behavior |
| --- | --- |
| Format / 格式 | Auto / 自动, Markdown, Plain Text / 纯文本; default Auto for new documents. Located beside the input actions and available from the reader action menu. |
| Resolved-format status | Auto · Markdown or Auto · Plain Text; accessible name explains the resolved format. Show no numerical confidence score or repeated suggestion banner. |
| Reading mode | The text labels Preview / 预览 and Source / 源码 appear in the Markdown reader after Apply or Translate. Preview is the default. Both original and translation switch together. Source is read-only; Edit Original opens the source editor. |
| Layout | Side by side / 左右对照, Sections / 章节对照 for Markdown. The latter uses the existing alternating-layout choice, labeled Paragraphs for plain text. Command-1/2 keeps its existing meaning. |

Run detection 300 ms after the last committed editor change, including paste. Suspend it during IME marked text. Apply, Save and Translate wait for a current-generation result; an obsolete parse cannot choose the format or replace a newer preview. The source plan stays tied to its revision during translation. The Preview and Source controls remain available. Interface-language changes do not change document format or translation direction.

Manual format selection wins over content detection. Remember the choice in the document, not as a global setting. Returning to Auto reruns detection for the current source. Changing the requested choice without changing its resolved format preserves units and results. A change of resolved format changes planning: if work/results exist, explain that applying it stops that job and clears its translation, and offer Apply Format / Cancel. This is the existing replacement boundary, not a new confirmation on every paste. Apply does not automatically start translation. Source/Preview switching, layout, width and appearance are presentation-only and make zero model calls.

### Sections and comparison

Preview and Source modes share the selected reading typeface on both language sides, defaulting to Menlo at 12 points with an 18-point baseline grid and native Chinese fallback. Preview retains heading sizes, emphasis, list layout and link styling. Literal metadata and unsupported literal blocks use the normal text background without added paragraph spacing between their lines; only actual code receives code shading. Presentation styles never alter source bytes or require retranslation.

Parse the whole source before building sections, including document-wide reference definitions. Every document-level ATX or Setext heading starts a section; headings inside lists, blockquotes, code or literal HTML do not. Preserve hierarchy through heading levels. Skipped heading levels keep their original level. Duplicate titles get distinct IDs. A heading owns the following blocks up to the next document-level heading of any level. Its child sections remain separate presentation groups; never duplicate their contents in a parent group. Leading content before the first heading forms one untitled introduction group.

This makes a document title followed by `##` sections a short title/introduction group followed by the actual section pairs, rather than one enormous pair containing the whole article. Hierarchy remains visible through heading size and spacing. Do not add artificial headings to exported text. Without headings, compare complete top-level structural blocks; keep a whole list or table together instead of pairing each source line. An empty document has no groups.

| Left/source group | Right/translation group |
| --- | --- |
| Document title and introduction | Translated title and introduction |
| First section heading, prose and list | Same section ID, translated heading, prose and list |
| Nested subsection heading and its own content | Same subsection ID and translated content |
| Next section | Corresponding next section |

Side by side aligns corresponding block starts using the larger intrinsic height, keeping each table together. Language-length differences leave space after the shorter corresponding block rather than accumulating a whole chapter of blank space. Both panes scroll at the same vertical offset, including when dragging either scrollbar. Logical block/section anchors restore the reading position after reflow or a mode change; they do not remap the other pane during a drag. Sections mode presents one source group followed by its translation, retaining the existing side key, distinct text styles and translation rule. Source mode keeps the same logical grouping with literal Markdown text, so it can diagnose formatting without requesting another translation.

Display completed blocks within an unfinished section; do not wait for a whole chapter. Completed paragraphs within list items appear progressively. Table headers and rows appear as complete rows with the correct column count. Keep unfinished indicators in the gutter/status area, not in selectable or exported text. A missing target block uses its source anchor. Preserve the current logical block when earlier results arrive.

### Selection, links, copy and export

Native Copy on an explicit selection copies the visible selected text. Copy Original and Copy Translation copy canonical source/assembled target Markdown, regardless of reading mode; full Copy Translation remains disabled until all required prose units complete. A document with only local-copy blocks is immediately eligible without a translation job; show No prose to translate instead of 0/0 progress or invented model attribution. File export offers Markdown (`.md`) or Plain Text (`.txt`) for Markdown documents. The latter contains visible content without markup; the former preserves structure and protected literals. A disabled full export and the existing explicit partial-export choice distinguish incomplete work.

Bilingual Markdown export serializes each source group followed by its translation, separated by application-generated language labels outside code/list/table blocks. Put the effective reference definitions before bilingual groups so the combined output resolves them with the original document's precedence. Translation-only Markdown export retains the original reference labels/definitions. Partial translation-only export includes only complete top-level blocks or section-owned blocks, omits incomplete lists/tables, preserves required reference definitions, and discloses omitted groups before saving. Bilingual partial export marks a missing translation outside the structural block. These labels never enter stored source or translations.

Links use an explicit Open Link context-menu action so ordinary selection does not navigate. Open HTTP/HTTPS destinations externally on request. Relative paths and other schemes remain available for inspection and copy. Fragment links use the source heading identity to reveal its corresponding heading on either side when uniquely resolvable; ambiguous or missing anchors do not guess a destination. Keep fragment destinations unchanged in Markdown export. Other renderers may derive different anchors from translated headings, so exported intra-document anchor navigation is not guaranteed in the first version; source/translated heading comparison inside Bipara remains identity-based. Images remain placeholders with accessible alt text and no automatic network or filesystem read. Task-list checkboxes are read-only.

Selection stays in the active text view and uses the system selection color. Preserve keyboard selection across paragraphs and table cells, app-owned accessibility labels, maximum reading size, light and dark themes, and both scroller styles.

## Validation boundary

Native selection, scrolling, focus, accessibility, appearance, revision changes and cancellation require actual macOS evidence. The [native integration report](../validation.md) records the exercised cases and incomplete gates. Real-provider behavior, account access, latency and translation quality remain separate checks.

## Reading details

Actual checks and remaining gates are recorded in [validation status](../validation.md).

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

Counts are completed translation units out of nonblank units. Present model attribution, task state and counts as one accessible static text element. Keep the elapsed clock out of its label so each tick leaves the announcement text stable. Use the actual job snapshot's model for attribution, for example `GLM Flash · 142/142 · 1m 23s`. The tooltip explains the vendor, model, effort, counts and elapsed time. At narrow widths collapse attribution to an accessible info control before hiding progress/time.

Use the system primary foreground for compact reading labels, job status and model metadata. Preserve the appearance-adaptive original and translation colors in the paragraph reading key.

Pending/gutter/status elements have no selectable model span. Partial assembly remains paragraph-atomic; never fabricate translation for uncommitted units. Copy and export retain their own canonical-text rules, including explicit missing-content markers in partial bilingual export. Capture paragraph/side anchors before progressive insertion and restore the same logical reading position after layout. A missing target uses the source paragraph anchor until real target text exists.

### Wider reading area

Add `Reading Width` under Settings → Reading: `Standard`, `Wide` (default), `Window`. These are global reading preferences; the selected reading layout stays per document. Use point measurements from the live content area, not screenshot pixels. For each column/pane, subtract the reading inset before applying the cap.

| Width | Side by side, maximum per column | Paragraphs, maximum single column |
| --- | --- | --- |
| Standard | 720pt | 800pt |
| Wide | 960pt | 1080pt |
| Window | Available pane width minus insets | Available pane width minus insets |

Use 32-point horizontal insets per pane, reduced to 24 below 1100-point window width. Center capped text within its pane and align each column heading to its actual text edge. Keep font size and line spacing unchanged; reduce excess margins rather than shrinking text. At narrow sizes available space remains the limit. Preserve the chosen layout, equal column division, paragraph start alignment, selection and anchor when width/font/appearance changes. Keep elapsed-time ticks out of paragraph measurement.

### Default titles and elapsed time

Create immediately visible, session-unique `Untitled 1`, `Untitled 2`, etc.; do not use punctuation-only titles such as `---`. Keep an increasing workspace-local counter, without a new durable identifier or a model call. A meaningful imported `.txt` filename can supply the title. For pasted Markdown, prefer a meaningful document-level heading, then a supported single-line frontmatter `title`, then meaningful body text. For plain text, derive the title on Apply or Translate from the first line containing a Unicode letter or number, skipping separators, fence markers and punctuation-only lines. Strip a simple leading Markdown heading/list marker for the title only; cap an automatic title at 48 grapheme clusters within the existing codec limit. Keep the full title in a tab tooltip/accessibility label. If no meaningful line exists, retain its numbered title. Existing `.bipara` titles and user-chosen titles stay unchanged. Title changes never mutate source bytes, document/session IDs or an existing on-disk filename. Use the title as the suggested Save filename.

Elapsed time belongs to the tab's current translation job, not the active toolbar model or a global stopwatch. Use one monotonic clock interval while queued/running, starting when a validated job enters queued state, including dispatch wait, provider requests and automatic retry/backoff. Do not sum concurrent batch durations. Stop on completed, paused or failed. Resume/Retry of the retained job adds another active interval; user pauses and idle time after failure are excluded. Fresh Translate/Retranslate resets time. Cancelled preflight or Retranslate confirmation does not start/reset it. Display whole seconds (`9s`), minutes/seconds (`1m 23s`) or hours/minutes (`1h 04m`), with a one-second UI refresh that cannot replan or remeasure text.

Timing is session-local. Do not infer old durations from unit completion timestamps, persist clock instants in `.bipara`, or change document schema for this feature. A reopened file has no historical elapsed-time display; if resumed, the timer covers activity since that open and its tooltip says so. This limitation must remain visible in the implementation report.

### Model scope and concurrent tabs

There is one committed, app-wide Active Model ID. It is the default for fresh Translate and confirmed Retranslate in any tab. Each job independently freezes provider, model, effort, profile and endpoint binding when it starts. Switching the picker from A to B does not migrate a running A job; another tab can start with B. Returning to the A tab still shows the global B picker and A in job attribution. Resume and Retry retain A. Replacing a completed translation with B still requires Retranslate confirmation. A portable reopened document requires an explicit local binding before further model calls.

Clarify the picker help text: `Default for new translations. Existing jobs keep their model.` Keep actual job attribution visible. Editing an A record's model/effort does not rewrite its existing snapshot. Deleting that record, changing its provider/Base URL or removing its credential can block later A dispatches; an already dispatched call keeps its captured configuration. Replacing a credential affects later dispatches through the retained binding. Recommend separate named A/B configurations for simultaneous work. Per-tab active pickers are outside the current product scope. Offline concurrent-model fixtures and live provider tests establish separate evidence layers.

### Close preference and English menus

Settings → General adds `Discard unsaved changes when closing documents`, initially unchecked, without a separate helper-text row. Enabling it is an explicit opt-in to discard, not autosave or session recovery. Save applies the preference; Cancel discards the draft. Apply it consistently to tab close, Command-W, main-window close and Command-Q. When enabled, skip only the dirty-document Save/Discard/Cancel stage and follow Discard. Keep `Stop translation and close?` for queued/running work, and retain the Settings-draft close review. Normal Save failures, source-replacement confirmation, provider consent and existing-file overwrite handling keep their own behavior. Turning the preference off restores ordinary prompts. Closing a tab cannot cancel another job or delete/overwrite a saved file.

App-owned menus, window titles, toolbar labels and dialogs follow the saved interface language; system-supplied menus follow macOS localization. Fresh preferences default to English. Settings → General → Interface Language supports English and Simplified Chinese under R13/R18. Keep one localized Settings item and Command-comma shortcut. Preserve the saved language when upgrading preferences.

### Implementation and acceptance

Read [native design](technical-design.md), [model settings](model-settings.md), [document format](document-format.md) and [acceptance cases](../testing.md#reading-acceptance). Preferences remain optional on read with explicit defaults; preserve model configurations, credentials, language, typography and corrupt/newer-record protection. No portable duration field is added.

Reading presentation, session timing/titles, Settings and close policy use the existing state/bridge boundaries. Exercise deterministic offline fixtures and actual native rendering in both appearances and layouts; a design preview is not native UI acceptance. Record actual application build, UI and packaged-runtime results separately from real-provider evidence.
