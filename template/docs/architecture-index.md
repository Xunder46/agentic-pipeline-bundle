# {{PROJECT_NAME}} — architecture index

> Scope: the whole repository (index only). The planner reads this first ("docs as cache"), and the
> reviewer uses each document's scope declaration to decide which docs a change can make false.

Every architecture document listed here must open with a `> Scope:` line naming the code it covers.
A document with no scope line is treated as covering everything and is re-checked on every change.

| Document | Scope | Summary |
|---|---|---|
| <!-- docs/architecture/<area>.md --> | <!-- src/area/** --> | <!-- one line --> |
