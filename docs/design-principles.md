# Design Principles

## Product purpose

Bipara should provide a simple, refined, and trustworthy bilingual reading experience. Prioritize translation fidelity, understandable correspondence, and reading comfort. Evaluate features by the user problem they solve.

## Simplicity

Choose the least complex implementation that meets the agreed behavior. Include testing, packaging, startup, upgrades, operations, and debugging in the cost assessment. Keep correctness safeguards and useful validation even when they require code.

Create abstractions for concrete differences and observed repetition. Keep model providers replaceable without building a generic plugin platform. Add a runtime, database, service, or orchestration layer only when its benefit and ownership are clear.

## Complexity decisions

When implementation complexity is high **and** expected benefit is limited, obtain the project owner's explicit approval before proceeding. Both conditions matter; this is not a blanket approval requirement for every technically difficult change.

Present a concrete proposal with:

1. The user problem and expected improvement.
2. Implementation, packaging, runtime, and maintenance costs.
3. A simpler alternative and the effect of postponing the change.
4. The scope to approve, a verification plan, and how the choice can be revisited.

General development authorization does not approve such a specific trade-off. Reuse an explicit approval for the same scope and effects. Routine, reversible details within an approved design can proceed autonomously.

The LangChain trial is an explicit project goal. It still requires an integration design that respects local execution and documents any additional runtime or process boundary.

## Native presentation

Use native Apple window, toolbar, menu, shortcut, selection, focus, and accessibility conventions. Keep primary actions discoverable and advanced configuration secondary. Prefer restrained surfaces and a small number of purposeful controls.

Typography is core functionality: choose appropriate system fonts and Chinese/English fallbacks, and tune text size, line spacing, paragraph spacing, readable column width, and visual hierarchy. Preserve system accessibility settings and provide a useful range of reading sizes. Evaluate both light and dark appearances.

Highlighting should be readable, subtle, and distinguishable from text selection. Avoid moving the document unexpectedly during hover. Treat stable scrolling, selection, and reading position as acceptance criteria. Use animation only when it helps explain a state change.

## Trust and responsiveness

Preserve the user's original text. Distinguish translation, correspondence, and optional explanatory content. Explain uncertain correspondence instead of presenting invented precision.

Keep the interface responsive during model calls. Show progress at a useful granularity, support cancellation, and preserve completed work when a later segment fails. Measure actual behavior before promising speed, memory use, or maximum document length.

## Collaboration and evolution

Use small, reviewable changes with named acceptance checks. Record important decisions in the owning project document. Keep proposals, adopted decisions, implementation, and acceptance evidence distinct.

Preserve future platform and provider options through narrow boundaries. Evaluate their costs when they become real requirements; a roadmap item is not authorization to implement it early.
