# Self-Test and Acceptance Plan

This plan specifies acceptance checks; actual existing evidence is recorded in the [native validation report](validation.md). The acceptance matrix is supplemented by [Settings and provider checks](#settings-and-provider-acceptance) and [reading checks](#reading-acceptance). [Development plan](development-plan.md) owns delivery order and commands. Never convert a missing prerequisite, historical result or skipped applicable suite into a pass for the new revision.

## Acceptance triggers

The maintainer initiates and completes acceptance before merge. Editing code, fixing a bug or completing implementation does not automatically start an acceptance round. During routine work, review the diff and run only narrowly scoped checks needed to verify the change; report acceptance as not run. Agents start the full offline suite, native UI acceptance, real-provider checks or distribution qualification only when explicitly requested for the corresponding scope. A request to edit code or open a pull request is not an acceptance or merge instruction.

For a requested round, use the relevant cases below and record the exact candidate and coverage. After acceptance, further changes require the affected cases to be checked before merge; unrelated results remain attached to their tested source. The maintainer confirms acceptance before merge. Release candidates retain the complete product and separate provider/installer gates in the [release procedure](releasing.md).

Git hooks continue to check public content on commit/push. Hosted offline CI continues on pull requests and pushes to main; those automatic checks do not launch native UI acceptance or real-provider calls and do not replace the maintainer's functional acceptance. Saving local files triggers none of these workflows.

## App functional acceptance

Run the product checks on the existing desktop using Bipara's own controls, a synthetic document, and the deterministic fixture gateway. The scope covers observable app behavior and its supporting integrity checks. Input-method candidate behavior, VoiceOver speech, global keyboard navigation, system appearance changes, Increase Contrast and Reduce Motion are outside this acceptance scope. Installer qualification has its own evidence under the [release procedure](releasing.md).

| Priority and area | Exercise in the app | Pass condition and evidence |
| --- | --- | --- |
| Essential · Input and translation | Paste and edit Chinese and English text. Import a UTF-8 text file. Translate both directions, including Automatic and an explicit direction. Try empty or ambiguous input. | Source text, punctuation and paragraph boundaries remain intact. Each nonblank unit is translated once in the intended direction. Invalid input gives an actionable message and sends no request. Use CORE-01–03, UI-01 and SET-07. |
| Essential · Bilingual reading | Switch between Side by side and Paragraphs while reading a multi-paragraph document. Select text in each direction and exercise highlight, Pin, Clear and Reveal. Include a repeated or ambiguous phrase. | Both layouts show the same original and translation, retain the reading anchor and preserve selection where applicable. Correspondence uses the right passage and labels fallback granularity. Layout switching and hover send no model request. Use UI-02–03, JOB-05 and READ-01–02. |
| Essential · Task recovery | Start a slow translation, cancel after partial results, then Resume. Inject a malformed response or timeout and Retry. Edit the source while a prior response is pending. | Completed results stay readable. Resume sends only unfinished units. A late result cannot change a replaced revision or a closed tab. Failures identify a recoverable action without losing the source. Use JOB-02–04, JOB-06–07 and MODEL-03–04. |
| Essential · Tabs and documents | Open two independent drafts or jobs. Switch and close tabs during work. Save and reopen a `.bipara` file offline. Copy or export text. Cancel a dirty close and try an invalid file. | Draft, progress, layout and selection belong to the right tab. Save/reopen preserves source, translation and attribution. Copy/export omits display markers. Cancellation and failed open/save preserve existing data. Use DOC-01–04 and UI-04–05. |
| Essential · Model selection and privacy | Add, edit, select and remove a test configuration. Switch models during a job. Simulate missing credentials, an invalid destination and a rejected request. Inspect fixture requests, files, exports and diagnostics. | New work uses the selected configuration and retained work uses its captured binding. Draft Cancel preserves committed values. Credentials stay scoped to the intended destination and absent from portable files, exports and diagnostics. Use SET-01, SET-07–08, JOB-04, MODEL-01 and PRIV-01–03. |
| Quality · Reading preferences and localization | Use the app's Light and Dark choices and adjust text size, width and correspondence color. Switch English and Chinese UI. Resize the reading window using its own controls. | Both layouts stay readable without clipping. Language changes apply to app-owned labels and preserve document direction and content. Preferences save and reload. Keyboard shortcuts and app-owned accessibility names and values work for the sampled controls. Use UI-02, SET-02, SET-06, THEME-01–03, A11Y-01 and READ-06–08. |
| Quality · Long-text responsiveness | Use the existing five-tab fixture with documents over 100 KiB and repeat the 30 measured app interactions. Cancel an active fixture job. | Preserve content and tab ownership. Meet the existing p95 ≤150 ms interaction and ≤200 ms local cancel targets on the recorded machine. Record timings and document size with the tested build. |

During a requested functional acceptance round, start with `script/check.sh`, then run the [native app fixture checks](../Tests/README.md) for the affected workflows. Run the essential cases first and resolve any source loss, wrong-tab write, credential exposure or unavailable core workflow before accepting the candidate. Follow with the quality cases and record their results separately. Record the build or source fingerprint, case, expected and observed behavior, and result as pass, fail or untested. Report the exact coverage of a focused run.

Run live translation as a separate product check after stating the provider, synthetic samples, request cap and cost budget. Cover both directions and a representative correspondence case for the authorized configuration. Check meaning, omissions, paragraph boundaries, failures and time to first usable result. Fixture outcomes cover app behavior with controlled responses. Live quality and compatibility require actual provider evidence.

## Test layers and fixtures

Use Swift tests for Core invariants, XCTest/UI tests for native behavior, pytest with strict schema/HTTP fakes for Python, and actual child-process integration tests for IPC. The same canonical JSON examples and prompt cases must cross the Swift/Python boundary. Test behavior at the public seam rather than duplicating private helper implementation.

The default suite is offline and fails on any unexpected network request. Add a test-only worker entry point under `Worker/tests` that injects a fixture model factory into the real protocol loop; do not ship a production flag that activates arbitrary fixtures or alternate executables. Release-entry-point tests still exercise real packaged startup/assets without an API key.

Build the following original synthetic fixture families, with deterministic seeds and exact source reconstruction assertions:

- Empty text, whitespace-only text, CR/LF/CRLF, leading/trailing blank lines, indented and whitespace-only paragraphs.
- Repeated words, mixed Chinese/English, decomposed accents, emoji with modifiers/ZWJ, supplementary CJK, and punctuation-only spans.
- Many short paragraphs, an oversized paragraph, a sentence without punctuation, and a long unbroken literal. Include boundaries just below/at/above each byte cap and a composed character longer than a unit bound.
- At least 100 KiB UTF-8 / 200-paragraph UI fixture, five independent tab documents, and near-1-MiB source for Core limit checks. Large fixtures need not invoke a provider.
- Corrupt `.bipara` content: duplicate IDs/keys, invalid ranges, old/unknown schema/prompt, mismatched revision, truncated UTF-8, wrong references, and translations without attribution.
- Provider responses: valid data, missing/duplicate/reordered IDs, extra fields, blank text, markdown-wrapped JSON, invalid quote, repeated quote, overlapping spans, truncated JSON, refusal, `length` finish, HTTP failures and timeouts.

[Prompt cases](../prompts/cases.json), corpus version 2, supply 26 small semantic cases (20 translation, six alignment). Their sample outputs are valid fixed responses for offline tests; live translation is judged by meaning and invariants, not exact wording. Fixtures contain no private document or real credential.

## Automated acceptance matrix

| ID | Behavior to prove | Main requirements |
| --- | --- | --- |
| ENV-01 | Full Xcode/SDK and Swift/Python/build versions verified; commands fail clearly when prerequisites are missing | R6, R12 |
| CORE-01 | Exact source preservation; paragraph/unit partitions have no loss/duplication or grapheme split; NFC/NFD-equivalent draft edits still advance revision and save the actual new code points | R1, R5 |
| CORE-02 | Batch/unit/context/input bounds hold for both languages, oversized sentences, and Unicode boundary cases; no infinite splitting | R1 |
| CORE-03 | Paragraph assembly, unit-to-target ranges and literal-fragment joins are deterministic; unfinished paragraphs are not shown as complete | R1–R5 |
| CORE-04 | Literal occurrence resolution, reverse direction, repeated text, discontiguous spans and fallback labels; canonically equivalent but code-point-different quotes are rejected | R5 |
| DOC-01 | Empty, untranslated, partial and complete document round trips preserve source/boundaries/results/attribution; open works offline | R1, R7 |
| DOC-02 | Reject invalid file/IDs/ranges/schema; never overwrite on open failure; new session IDs isolate copied files | R15 |
| DOC-03 | Save-before-Translate/Apply persists current drafts without a key/call; empty/whitespace drafts round trip; save failure keeps draft/dirty state; concurrent saves cannot overwrite newer snapshots; another tab’s destination is rejected; a result arriving during save remains dirty | R15 |
| DOC-04 | Read schema 1 and write schema 2 with preserved IDs/text/results/profile and derived Auto/Off; unknown future schema never rewrites; snapshot effort round trips; endpoint/key/alias/configuration ID absent; opened documents require explicit matching local binding before Resume/uncached alignment; reading and binding make zero calls | R8, R17 |
| JOB-01 | Global physical operations <=4, up to two translation batches per document session, round-robin documents and alternated alignment admission; a terminal batch failure stops dispatch while in-flight siblings drain and may commit | R15 |
| JOB-02 | Cancel/resume keeps completed units and does not resend them; queued and active cancellation differ correctly; no late commit | R1, R15 |
| JOB-03 | Tab switch/close, source edit, same-title replacement, copied-file session, and worker replacement cannot receive stale results | R5, R15 |
| JOB-04 | Default/model/effort edits do not mutate job snapshots or frozen endpoint; same-URL key rotation applies to new dispatches; deleted/changed-endpoint entries block later calls without retargeting and leave dispatched work intact; retranslation is explicit; unrelated batch completion preserves unit target generations, pin/cache and alignment; resumed holes reproject later selections; copied-file sessions have isolated caches including effort/private binding identity, cleared on explicit rebind | R8, R14, R17 |
| JOB-05 | Hover makes zero calls; unchanged selection/cache hits make no extra call; debounce and superseding selection cancel correctly | R5, R9 |
| JOB-06 | A translation unit mismatch replaces only the failed original batch with two ordered halves, each with its own source context. Existing results stay readable, recovery uses normal admission, and a failed half stops without further splitting | R1, R15 |
| JOB-07 | GLM 429 with `1302` or `1305` cools the affected configuration without holding a physical slot. Other routes continue. The affected route admits one request at a time after cooldown and prioritizes the failed batch for one replay. Check cancellation, delay budget, second failure, quota and unknown-code cases | R1, R15 |
| IPC-01 | Handshake/version/assets/startup failure; no key before ready; no dependence on developer PATH or working directory | R7, R12 |
| IPC-02 | Byte-fragmented UTF-8, concatenated frames, escaped newlines, out-of-order results and concurrent writes decode correctly | R12, R15 |
| IPC-03 | Bad frames, duplicate decoded keys (including escaped aliases), duplicate active IDs, oversized buffers, stdout pollution and incompatible versions fail safely; repeated key names in distinct objects remain valid | R12 |
| IPC-04 | Cancel/success race emits one terminal event; tombstone releases slot without committing; other operations are unaffected normally | R15 |
| IPC-05 | EOF, crash, shutdown escalation and restart resolve pending tasks without orphans; a normal 120s provider timeout fails only that request, whereas no terminal by the 130s watchdog fails the worker instance | R7, R12 |
| IPC-06 | Protocol 2 rejects a protocol-1 worker before credentials; config URL/effort required and validated on both sides; requested-effort metadata must match; new app/worker ship together; legacy profile IDs still work inside v2 envelopes | R8, R12, R17 |
| MODEL-01 | Captured URL/body matches selected legacy/v2 profile; OpenAI retains strict JSON Schema/no tools and correct completion cap; GLM uses max_tokens/JSON object and its model-specific thinking/effort; legacy sampling guards remain enforced, while v2 reasoning intentionally omits sampling; silent URL/model/effort/cap/message/mode mutations fail before HTTP; absent/false stream accepted | R8, R17 |
| MODEL-02 | Exact two messages and prompt hashes; document text cannot become template/system instructions; no credentials/UI state in prompts | R8, R9 |
| MODEL-03 | Strict shape plus semantic validation rejects every malformed response fixture; finish/refusal checks precede result commit | R1, R5 |
| MODEL-04 | Every operation makes at most one HTTP call; no retry/repair/fallback; rate-limit, timeout, quota, refusal and capability errors normalize correctly | R8 |
| MODEL-05 | Capture every capability entry and supported effort: GPT-6 Luna Off maps to none; GLM-5.3/Flash Low enables thinking and sends low; Off/On/Minimal/Medium/Extra high rejected for those GLM entries; GLM-4.7-Flash Off/On never sends graded effort; GLM-5.2 Off disables thinking and Minimal is sent verbatim; OpenAI entries without Off (astra/6.1-sol) and without Max (5.5/5.4/5.2) reject those values; Auto differs from Off; unknown models allow only Auto; Standard/Coding URLs retain their distinct path/key; cap includes reasoning; no silent clamping, model remap or API change | R8, R17 |
| PROMPT-01 | Both schema files accept all sample outputs; semantic checks validate unit IDs, status/match combinations, and literal occurrences | R1, R5 |
| PRIV-01 | Provider-credential/app-private-path canaries introduced through configuration (not document content) never leak to documents/exports/logs/errors/model messages; user-text canaries are absent from diagnostics, model metadata, telemetry and implicit host persistence. Text is permitted in explicit document/draft state, user-selected files/clipboard, and the necessary disclosed model input. Tracing is disabled | R7, R11 |
| PRIV-02 | Keychain failures do not partially apply Settings silently; Cancel/close behavior preserves prior settings; deletion/rotation is scoped | R14 |
| PRIV-03 | Equal key values remain independently scoped per configuration; endpoint changes clear draft key and require re-entry, reverting URL restores original draft state; old jobs cannot read a new endpoint's key; consent is per provider/origin; private endpoint/alias/credential/configuration canaries absent from saved files, prompts, logs and errors; redirects/environment overrides cannot forward credentials | R7, R11, R17 |

Milestone acceptance is cumulative: M0 records only the explicitly listed IPC/package smoke subsets, M2 completes IPC/JOB plus local/transport privacy, M3 completes real model-message privacy, and M5 completes local installation/upgrade and distribution coverage under the declared OS support policy. A partial acceptance ID stays marked partial until its full listed behavior passes.

Use fake clocks/scheduled responses to make concurrency and deadlines deterministic. Include adversarial ordering rather than only happy-path snapshots. Run the real worker process offline for transport assertions, not only two language-local codec mocks. Inject short test deadlines without changing production constants. For negative tests, assert both the visible error and absence of a mutation/network call.

## Native interaction acceptance

| ID | Run in the actual macOS app |
| --- | --- |
| UI-01 | Paste/import and edit bilingual text, direction selection/Auto, empty state, editing Apply/Cancel, source revision invalidation |
| UI-02 | Both layouts at 900×650 and a larger window; 14/17/28-point text; Chinese/English font fallback and readable paragraph spacing |
| UI-03 | Hover, native drag/double-click/keyboard selection, pin/clear/reveal, offscreen counterpart, line wrapping, reverse selection; no unexpected scroll jump |
| UI-04 | Tab add/switch/close, input draft preservation, background progress, independent layout/selection/scroll, final-tab empty workspace |
| UI-05 | Dirty/running close, Save/Discard/Cancel, failed save, quit cancellation, reopening window, Cmd-W responder routing and main-menu enablement |
| SET-01 | Draft Save/Cancel including model CRUD/default/keys, masked key replace/delete, English/Chinese UI switching without changing document direction |
| SET-02 | Shared typography across tabs; reading anchor and selection survive preference/layout changes; in-flight model snapshot unchanged |
| SET-03 | Default picker independent of model list/editor; list shows only resolved name and effort; multiple same-model configurations; first-add default, deletion replacement/cancel, nondefault deletion, empty list and missing-key Translate preflight |
| SET-04 | Native Add/Edit sheet; actual ID vs optional alias; duplicate name/effort requires disambiguation; four effort choices; exact Base URL validation/path joining; complete draft cancel/close behavior; no call on Save or protocol/effort selection |
| SET-05 | Existing provider models/default/keys/language/appearance/typography migrate once offline; missing keys remain missing; failed Keychain copy/record save compensates; cleanup failure reports residue; repeated launch retains IDs; corrupt/newer v2 never falls back or resets |
| SET-06 | Exactly one Settings app-menu command and Command-comma shortcut with reader or Settings focused, English and Chinese; localized window title; menu/toolbar/shortcut opens or focuses the same window; live language switch preserves a settings draft |
| THEME-01 | System mode matches the current effective appearance. Use Bipara's Light and Dark choices to verify both reading layouts |
| THEME-02 | Switch Bipara's appearance during translation. App windows, sheets, text and highlights update without restarting or sending a model request |
| THEME-03 | Selection vs correspondence remains distinguishable in both appearances; disabled controls, errors, placeholders and secondary labels remain readable |
| A11Y-01 | Check app-owned shortcuts, localized names for native text and controls, static task status, and the reading-size slider's current value. Verify correspondence and progress cues can be distinguished without color alone. Use the existing desktop configuration |

Capture screenshots or XCTest attachments for both layouts in the app's Light and Dark appearances and concise notes for stateful interactions. Include Chinese UI and the app Settings window. Inspect the running macOS app for native visual acceptance.

Initial responsiveness targets on the recorded development machine: ordinary tab/layout/selection interaction p95 <=150 ms over 30 fixture interactions after initial loading; cancellation reflects locally within 200 ms; a cooperative fixture worker cancels within 1 second; no main-thread file/model/pipe blocking or beachball. Measure with the 100-KiB/five-tab fixture and report traces if a target fails. These are design targets to evaluate, not promised device-wide SLAs. Record cold/warm worker startup, RSS and bundle size; the hard startup timeout remains 10 seconds. Return material target changes for design review instead of weakening tests silently.

## Settings and provider acceptance

Run the existing offline suite and native fixture workflow during the requested acceptance round. Keep previous evidence attached to its tested revision.

| ID | Evidence |
| --- | --- |
| SET-07 | General exposes Automatic and both explicit directions. Fresh and upgraded preferences default to Automatic. Save/Cancel behave correctly. Ambiguous recognition retains text/results, offers Settings, and makes zero requests. Interface language remains independent. New Translate and confirmed Retranslate capture current values. Resume, Retry and correspondence keep their recorded direction/model even after either picker changes. |
| SET-08 | Verify Add/Edit fields and profile-specific options against the [model configuration contract](design/model-settings.md) for the tested build. Preserve custom/legacy IDs and existing keys on upgrade. Test same-model instances, visible row metadata, empty state, deletion replacement, the toolbar position and shared selection after restart. Verify app shortcuts and narrow toolbar behavior. Exercise a toolbar switch while Settings has unrelated edits, an explicit selection edit or a staged deletion. |
| SET-10 | Exactly six fields ordered Name, Protocol, Model ID, Reasoning Effort, API Base URL and API key. New text fields are blank; both protocols and all four efforts remain selectable without filling text. No preset, vendor, catalog or Advanced controls. Verify manual custom input through outer Settings Save and reload for both protocols without vendor labels, active selection and key retention, Save/Cancel, stored-option preservation, legacy conversion requiring an explicit effort choice when needed, native screenshots and localized labels. |
| MODEL-07 | Capture actual HTTP bodies for both protocols, both operations and all four efforts. Check URL prefixes/full overrides, auth/secret headers, output modes, temperature omission/zero, token caps, optional JSON precedence, malformed inputs, refusal/truncation, cancellation and no retry/redirect. Pass the same profiles/options through the packaged Swift/Python pipe. |
| DOC-05 | Round-trip open-profile attribution without endpoints/options/credentials. Frozen options survive saved edits; effective edits rotate the configuration revision and prevent stale portable rebinding. Alias/vendor-label edits retain credentials, while protocol/URL/auth changes invalidate them. Existing records and retained legacy requests remain unchanged without explicit conversion. |
| SET-09 | Read the packaged app's two Info.plist values and inspect the native About panel. Confirm both the release version and build can be identified from the display. |
| MODEL-06 | Capture final bodies for every new catalog entry and effort. Verify Kimi uses `max_completion_tokens` and never sends `thinking` for featured models, DeepSeek uses `max_tokens` and its selected thinking mode, and GPT-6 Sol sends the correct effort and strict schema. Exercise blank output, truncation and errors without extra requests. Prove same-URL vendor changes and URL changes cannot deliver another binding's key, and a restored binding follows the existing key rules. Verify new provider attribution through the portable file and explicit rebind paths. |
| PERF-REV | Record cold and warm stage timings, time to first complete paragraph and total completion on identical short and multi-batch bilingual fixtures. Compare explicit effort settings under the same endpoint, then compare candidate models. Check quality, completeness, errors and call count alongside latency. Try a smaller first batch only when baseline evidence warrants it. |

Use endpoint-scoped eligible test accounts for opt-in real calls. Extend the live verifier to take explicit Kimi and DeepSeek test credentials before claiming real acceptance for them. Keep historical model profiles and the existing offline no-network rule covered.

## Reading acceptance

The [reading refinements](design/interaction.md#reading-details) define the following acceptance requirements. Current outcomes belong in [validation status](validation.md).

| ID | Evidence |
| --- | --- |
| READ-01 | In both layouts inspect idle, queued, progressive, paused, failed and completed fixtures. No repeated untranslated text or per-pair Original/Translation labels. Completed text stays readable, unfinished locations remain identifiable, pane status is nonselectable, and canonical copy/export/analysis never includes presentation markers. Verify target-side anchors when a translation first appears. |
| READ-02 | Resize the app to 900×650 points and a wider size available on the current display. Test all three width choices and both layouts with 17pt and 28pt type. Actual line width follows content space/caps and headings align to text edges. Preserve selection, pin and paragraph position across resize and width changes. Confirm more content per line at a wide window. |
| READ-03 | Create several empty tabs; each has a nonempty distinct title. Apply/import text beginning with blank lines, `---`, headings, list markers and emoji. Verify the first meaningful title, punctuation-only fallback, grapheme-safe truncation, filename suggestion, existing-title preservation and unchanged source bytes/IDs. No title-generation request. |
| READ-04 | With an injected monotonic clock, verify active intervals across queueing, parallel batches, automatic backoff, cancel, failure, Resume/Retry and fresh Retranslate. No double counting; tab switching and wall-clock changes do not affect ownership/time. Preflight/cancelled replacement does not reset time. Reopen has no invented historical duration; resumed timing explains its limited coverage. Clock ticks leave the accessible status label stable and do not remeasure reading text. |
| READ-05 | Start tab A on model A, switch the global picker to B and start tab B. Fixture captures prove A continues with frozen configuration and B uses B. Check actual-model attribution, picker help, Resume/Retry/analysis, record edits/deletion and portable rebind. Keep live provider concurrency/latency evidence separate. |
| READ-06 | For all four highlight presets inspect both layouts in Bipara's Light and Dark appearances, including source/translation colors, native text selection, hover, counterpart and pin. Verify at least 4.5:1 reading-text contrast and a non-color cue. Change the app appearance or preset while the same ranges remain highlighted. Repaint immediately with selection, pin and anchor preserved and zero model calls. Save/Cancel and preference reload retain intended values. |
| READ-07 | With skip-save off/on test tab close, Command-W, main-window close and quit for dirty/clean and running/paused/completed tabs. On skips only document save review, discards unsaved changes, retains running-stop and Settings-draft confirmations, and never writes/deletes saved files or affects another tab. Cancelled/failed explicit Save preserves open content. |
| READ-08 | Switch a saved Chinese preference to English and Save. Inspect all app-owned menus, titles, toolbar, status and alerts, plus one Settings command/Command-comma in both focused windows. Preserve document text/direction/results and the explicit Chinese option. Load legacy records missing new fields with proposed defaults while preserving models, keys, language and typography; corrupt/newer records remain protected. |

## Translation prompt v2

The active translation prompt targets logical scope, omissions and protected technical syntax. It is effective for new jobs; older snapshots keep their recorded prompt. No model-quality pass may be inferred from fixture responses or a completed-unit count.

| ID | Required evidence |
| --- | --- |
| PROMPT-02 | T07–T10: review alternative prerequisites against every listed truth-table row; distinguish necessary from sufficient conditions, both from either, exceptions and fragment boundaries. Reject a changed permission/prohibition even if fluent. |
| PROMPT-03 | T11–T14: account for each list member, clause and qualifier; distinguish instruments/tools, forecast/observation windows, item names/issues, both surprise directions and priced-in extent/money. Reject accidental untranslated prose; intentional names/literals remain permitted. |
| PROMPT-04 | T15–T20: check each `literal_checks` invariant in the actual output and assembled document, while confirming descriptive prose was translated. Preserve frontmatter delimiters/keys, list/heading markers, emphasis, links, code fences, JSON syntax/booleans and table separators. Restore source paragraph separators/indentation without adding fences or normalizing syntax. A saved plan splitting `1.` from its body must retain the original following spaces/tabs and correct target ranges, including an indented CRLF document. |
| PROMPT-05 | Offline: new/retranslated jobs capture v2; v1 and v2 partial jobs Resume without resending completed units, dispatch the recorded asset, and reject mismatched result prompt attribution. Both canonical assets reach packaged helpers unchanged. Source and portable-document schema remain unchanged. |

Run the default `script/check.sh`. Focused fixture checks are `uv run --project Worker --frozen pytest Worker/tests/test_assets.py Worker/tests/test_prompt_cases.py Worker/tests/test_models_operation.py Worker/tests/test_protocol.py` and `swift test --build-system swiftbuild --no-parallel --filter PromptVersionTests` after worker packaging. These checks establish corpus validity, literal expectations and version plumbing, not live semantic quality. For a v1/v2 comparison, hold text, unit boundaries, model, endpoint and effort constant; record the prompt hash and version separately, apply the same critical-case rubric, and report latency/usage/failures only when measured. Live calls retain the opt-in gate below.

## Live provider gate

This gate is opt-in, uses configured eligible accounts, can incur charges, and is never part of the default offline suite. The live verifier must require `--allow-paid-requests` and a maximum call count. It reads only the explicitly named provider test credential, never a full environment dump or an arbitrary dotfile. Use synthetic corpus content only. No automatic retries.

For each selected eligible endpoint product/provider/model/profile/effort, recording all five explicitly (registration presets alone do not establish account entitlement):

1. Execute all 26 prompt cases (20 translation, six alignment). Record raw results only in local synthetic evaluation artifacts; report prompt hashes, actual model attribution, schemas, counts and semantic findings. Plan the full run's batch/call count first; the expanded corpus does not raise the cap below.
2. Translate one Chinese and one English synthetic long document, each at least 20 KiB UTF-8, including multiple paragraphs and an oversized paragraph. Calculate the exact planned batch count before sending and enforce the **40 calls/provider** cap across the whole run. If that cap is insufficient, stop and report an incomplete run; do not silently increase it.
3. Verify all IDs/units commit exactly once, final source is unchanged, paragraph count/ordering is preserved, no unexplained omissions/additions occur, and cancellation/resume does not resend completed units.
4. Include three alternating direct-call/LangChain pairs on T01 using equivalent final request bodies, within the same total call cap. Treat the six calls as a small feasibility comparison, not a statistical latency claim. In the native app, exercise both providers, background tabs, phrase selection, attribution and error presentation. Repeat network loss/cancellation without assuming a cancelled remote operation was unbilled.

Pass criteria: 100% structural validity and source coverage for accepted results; all 20 translation cases preserve their listed critical facts and protected literals; all six alignment cases meet their listed semantic expectation, including no false exact match for the omitted article/idiom. A no_match fallback in a clearly matchable fixture is safe behavior but fails the quality gate for that fixture. For long texts, inspect first/last paragraphs, every split boundary, all negations/numbers/names, and a deterministic sample of remaining units; report that sample rather than claiming every sentence received human semantic review.

Semantic evidence requires independent human review; an LLM is not the unreviewed sole judge of its own output. A verifier may check structure and literals. Network/authentication/model failures block provider acceptance; fixtures cannot replace real evidence. Failed cases require a versioned design correction.

## Packaged runtime and public-content gate

| ID | Required evidence |
| --- | --- |
| PKG-01 | Copied app runs from a path containing spaces without repo paths/system Python/uv/pip; helper resolves bundled assets, no startup downloads/listeners or helper Dock icon |
| PKG-02 | Exact final DMG installed and upgraded on the maintainer's local Mac running macOS 26 or 27; record its checksum and exact OS version, exercise launch/read/save/model/quit smoke, and preserve settings/documents/Keychain during upgrade. Check every bundled binary's deployment target. Other OS versions and clean-machine behavior remain unverified; neither stripped PATH nor a fresh user account proves clean-machine isolation |
| PKG-03 | Nested binaries and main bundle signature verification under the tagged distribution policy. Initial ad-hoc packages disclose missing Developer ID/notarization and demonstrate the expected warning plus per-app exception on the tested local system. The optional Developer ID policy additionally requires actual notarization/Gatekeeper acceptance |
| PKG-04 | Repeated launches/quits and app crash leave no orphan worker; packaged cancellation and two requests behave like development tests |
| OSS-01 | Dependency versions/licenses, asset provenance, portable setup, English docs and default UI, ignored artifacts and no private addresses/paths/secrets; no unapproved license or publication |

## Report template

Use this structure for private evidence in `.local/validation/`. Update `docs/validation.md` only with concise current results and limitations.

```text
Revision/base and scope:
Environment (OS, architecture, toolchain, generic hardware class):
Dependency lock and prompt/schema hashes:
Acceptance IDs exercised:
Commands and exit codes:
Pass / fail / skip counts, with reasons:
Offline evidence:
Live API evidence (provider/model, call count, quality findings):
Native UI / accessibility / appearance evidence:
Packaged-runtime and signing evidence:
Known blockers, deviations and unresolved technical questions:
Privacy/public-content self-check:
```

Before a completion claim, check the intended diff, source integrity, failed/skipped gates, generated artifacts, secret boundaries, and side effects. Report which layers actually ran. Passing documentation or JSON fixtures is not an application acceptance result.
