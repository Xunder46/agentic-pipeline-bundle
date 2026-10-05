# {{PROJECT_NAME}} — conventions

> The binding, cross-cutting rules every agent runs as a checklist on every task. Plans reference this
> file by path and never copy it. Keep each rule short, checkable, and about something an implementer
> could plausibly break without noticing. Delete the guidance comments as you fill sections in.

## 1. Layering and dependency direction

<!-- The allowed import edges between {{MODEL_DIR}}, {{PERSISTENCE_DIR}}, {{STATE_DIR}}, {{UI_DIR}},
     {{SHARED_UI_DIR}} and {{CORE_DIR}}, and the grep that proves each one. Example:
     "{{STATE_DIR}} depends on {{DATA_INTERFACE}} only — never a concrete implementation." -->

## 2. Persistence

<!-- Implementation parity between {{PRIMARY_IMPL}} and {{TEST_IMPL}}; one contract test suite runs
     against both; every new interface method ships in both, in the same change. Migrations and the
     schema artifact ({{SCHEMA_ARTIFACT}}). -->

## 3. Naming, errors, shared utilities

<!-- Where formatting, dates, money/units and constants live, so nobody re-implements them. -->

## 4. Tests

<!-- Scenario IDs in test names; fixtures as enumerated by the plan; which suites are golden/snapshot
     and which OS they must be generated on; the red-before-green rule for bug fixes. -->

## 5. Documentation

<!-- Every doc under {{DOCS_ROOT}} opens with a scope declaration (which code it covers). Docs trail code
     by zero phases. Behaviour is pointed at by a test, not restated in prose. -->

## 6. Invariant checks

<!-- The greps/commands that must stay clean on every change. Mirror them into INVARIANT_CHECKS in
     pipeline.config so the governor and every brief carry them. -->

## 7. Things this project keeps getting wrong

<!-- Grows from `/retro`. Each entry: the rule, why, and the guard (test/lint/CI) that enforces it. -->
