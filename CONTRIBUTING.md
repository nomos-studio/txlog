# Contributing to txlog

txlog is a monorepo. Language clients are peers inside it:

```
cpp/   C++ library        (edn-cpp + SQLite3, C++20)
clj/   Clojure library    (next.jdbc + sqlite-jdbc)
cl/    Common Lisp daemon (cl-sqlite + bordeaux-threads)
py/    Python tooling     (stdlib only)
spec/  Format specification
```

Each peer follows its own build and style conventions. This document covers
the conventions that apply across the whole repo, plus per-peer notes for
the peers that have automated enforcement.

---

## Licensing

txlog is MIT licensed. See `LICENSE`.

**Why MIT rather than BSL-1.0?**

[edn-cpp](https://github.com/cljseq/edn-cpp) chose BSL-1.0 — a natural fit
for a standalone C++ library targeting a C++-ecosystem audience. txlog is
different: it is a multi-language monorepo whose Python and Clojure peers
live in ecosystems where MIT is the expected default. More importantly, the
C++ peer will be linked into the CLAP audio container alongside the Ableton
Link library (GPL) and the cljseq sidecar (LGPL, or GPL when Link-dependent).
Both MIT and BSL-1.0 are GPL-compatible — MIT code can be freely incorporated
into a GPL binary — but MIT is shorter, simpler, and more universally
understood. When in doubt, reach for the simpler licence.

All source files carry an SPDX identifier on the first line:

```cpp
// SPDX-License-Identifier: MIT
```

```clojure
;; SPDX-License-Identifier: MIT
```

```python
# SPDX-License-Identifier: MIT
```

---

## Git hooks

Project hooks live in `scripts/` and are checked into the repo. Install once
after cloning:

```sh
bash scripts/install-hooks.sh
```

The pre-commit hook (`scripts/pre-commit`) blocks on:

- Credential file extensions (`.pem`, `.key`, `.env`, …)
- Known secret patterns (AWS keys, PEM headers, API key assignments, …)
- Hardcoded absolute personal paths (`/Users/<name>/…`, `/home/<name>/…`)
- C++ files that do not pass `clang-format --dry-run --Werror`

If `clang-format` is not installed, the format check is skipped with a warning.
Emergency bypass: `git commit --no-verify`.

---

## cpp/ — C++ peer

### Build system

- **CMake 3.20 minimum.** C++20 required; C++23 features used opportunistically
  via feature-test macros with C++20 fallbacks.
- `FetchContent` for external dependencies at pinned tags; `GIT_SHALLOW TRUE`.
- `FETCHCONTENT_UPDATES_DISCONNECTED ON` — skip network on subsequent builds.
- Tests use **Catch2 v3**.

```sh
cmake --preset dev -DEDN_CPP_DIR=/path/to/edn-cpp
cmake --build --preset dev
ctest --preset dev
```

### C++ formatting

All C++ source files are formatted with **clang-format** using `.clang-format`
at the repo root (4-space indent, 100-column limit, left pointer/reference
alignment). The pre-commit hook enforces this automatically.

Format a file:

```sh
clang-format -i cpp/src/txlog.cpp
```

Format all C++ sources at once:

```sh
clang-format -i cpp/include/txlog/*.hpp cpp/src/*.cpp cpp/tests/*.cpp
```

Check without modifying (same as CI):

```sh
clang-format --dry-run --Werror cpp/src/txlog.cpp
```

### C++ naming and style

- All types and functions: `lowercase_snake_case`, matching `std::` conventions.
- No `CamelCase` types; no Hungarian prefixes.
- Namespace everything under `txlog`.
- SPDX identifier on the first line of every header and source file.
- `#pragma once` (not include guards).
- No exceptions in library code; `std::optional` / result types at boundaries.
- No raw `new`/`delete`; value semantics by default.

### Comments

Write no comments by default. Add a comment only when the **why** is
non-obvious: a hidden constraint, a subtle invariant, or a workaround for a
specific bug. Never describe what the code does.

### clangd / IDE

```sh
cmake --preset dev          # sets CMAKE_EXPORT_COMPILE_COMMANDS=ON
ln -sf build/compile_commands.json compile_commands.json
```

---

## clj/ — Clojure peer

Run tests:

```sh
cd clj
clojure -X:test cognitect.test-runner.api/test :dirs '["test"]'
```

No automated style enforcement is configured yet. The Clojure standard style
(2-space indent, idiomatic `ns` declarations, `kebab-case` names) is expected.
`range` is excluded from `clojure.core` via `(:refer-clojure :exclude [range])`
because the txlog API defines its own `range` query.

---

## cl/ — Common Lisp peer

Load and test via ASDF:

```lisp
(asdf:load-system "txlog")
(asdf:test-system "txlog")
```

Or run the fiveam suite directly in a REPL:

```lisp
(txlog/test:run-tests)
```

No automated style enforcement is configured yet. Standard CL conventions
apply: `(defun kebab-case ...)`, `+constant+` naming for `defparameter`
constants that are treated as constants, `*global*` for dynamic vars.

---

## py/ — Python peer

No peer exists yet. When added: `pyproject.toml`, stdlib only (no EDN library
dependency — the txlog EDN subset is narrow enough to parse directly), `pytest`
for tests, `ruff` for formatting.

---

## Monorepo conventions

- Each peer's `README.md` documents that peer; the root `README.md` is the
  format overview.
- CI fans out per peer; failing one peer does not block the others.
- The `spec/` directory is the authoritative format reference. Schema changes
  go there first, implementations follow.
- No cross-peer build dependencies — `cpp/` does not depend on `clj/` at build
  time and vice versa. The format (SQLite + EDN) is the only interface.
