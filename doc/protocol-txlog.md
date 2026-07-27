<!--
SPDX-FileCopyrightText: 2025-2026 nomos-studio contributors

SPDX-License-Identifier: MIT
-->

# txlog format

**Owning component:** `txlog` — the transaction-log format and its reference clients
(`cpp`, `clj`, `cl`). This document specifies the on-disk format.

**Normative sources:** `cpp/include/txlog/txlog.hpp` (the `entry` struct + `source`
vocabulary) and `clj/src/txlog/core.clj` (the entry map + SQL). Until a dedicated
`spec/` exists, those two are the reference; this document consolidates them.

## Purpose & ownership

The tx_log is a durable, replayable record of state changes — musical *and* workflow.
**The format is its own thing; nous is one participant.** Any conforming tool that
speaks **EDN + SQLite** is a peer — there is no shared library across clients, only the
format. "The format (SQLite + EDN) is the only interface."

## Boundary parties

| Role | Who |
|---|---|
| Writers / readers | `txlog-cpp` (C++), `nous` via `txlog` clj, `txlog-cl` (SBCL, planned) |
| Producer of nous's log | `nous.ctrl` / `ctrl-tree` (emits changes as it writes) |

## Transport & framing

An **SQLite database** with a `changes` table; each row is one change `entry`. EDN
values are stored as `pr-str` strings in text columns and read back with `read-string`
(a narrow EDN subset — keywords, numbers, strings, booleans, vectors/maps of those —
so a client can parse it without a full EDN library).

## Record vocabulary — the `changes` table

| Column | Type | Meaning |
|---|---|---|
| `id` | UUID (16-byte) | unique tx id; caller-assigned before emit |
| `beat` | double | musical / human-scale time |
| `wall_ns` | int64 | wall-clock nanoseconds (POSIX epoch) — **the cross-log merge key** |
| `source` | EDN keyword | provenance (see vocabulary below) |
| `path` | EDN value | the changed path — a vector of keywords in practice |
| `before` | EDN value | value before the change; **absent on insert** |
| `after` | EDN value | value after the change; **absent on delete** |
| `parent` | EDN value | causal parent tx id, if any |

SQL shape (clj reader): `SELECT id, tx_id, beat, wall_ns, source, path, before, after,
parent FROM changes`. The clj entry map mirrors it: `{:id :beat :wall-ns :source :path
:before :after :parent}` (nil where a column is absent).

## Source vocabulary — EDN keyword namespaces

| Namespace | Meaning |
|---|---|
| `:txlog/<name>` | **format-owned** — every txlog-aware tool should understand it. Defined: `:txlog/user`, `:txlog/schema`, `:txlog/error`, `:txlog/undo` |
| `:org.nous/<name>` | nous-specific — opaque-but-valid to non-nous tools (e.g. `:org.nous/loop`) |
| `:<org>/<name>` | open extension — any participant uses its own namespace |

## Two-file model

A session keeps more than one log (e.g. a music log and a workflow log). They are
independent SQLite files; `wall_ns` is the common axis on which entries from different
logs **merge into a single wall-clock-ordered timeline** — the reason wall_ns is
recorded on every entry alongside `beat`.

## Read model

Beyond raw rows, the reference clients expose derived queries (see `txlog.hpp`):
`at(path, beat)` (value of a path at a musical time), `range(...)` (filtered entries),
and `crystallize(beat_from, beat_to)` → a *timeline* (`path → [{beat, value}]`) — a
projection used to reconstruct state or render notation from the log.

## Thread safety

`emit()` / `register-source` are serialised (internal mutex on C++, `locking` the
connection on clj); reads rely on SQLite's serialised / WAL mode through the same
connection. Do not share one log instance across processes.

## Stability & versioning

Column set and the `:txlog/*` vocabulary are the contract; append-only. A tool that
does not recognise an `:org/<name>` source treats it as opaque-but-valid. Because
clients share no code, the format revision (this doc + the two reference sources) is
the shared contract — change it in lockstep across clients.

## Reimplementing a client

Open the SQLite file, read/write the `changes` table with the columns above, and
`pr-str`/`read-string` the EDN value columns. That is the whole contract — no txlog
code is linked. `txlog-cpp` and the `clj` client are the reference implementations.

## Related

- Product boundary index: `../../nomos-studio/doc/component-boundaries.md`
- EDN codec (C++): the `edn-cpp` component.
