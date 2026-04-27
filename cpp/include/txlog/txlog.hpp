// SPDX-License-Identifier: MIT
#pragma once

#include <edn/builtins.hpp>
#include <edn/value.hpp>

#include <cstdint>
#include <map>
#include <memory>
#include <optional>
#include <string>
#include <string_view>
#include <vector>

// ---------------------------------------------------------------------------
// txlog — C++ library for reading and writing the cljseq transaction log.
//
// Format ownership: the tx_log format is its own thing; cljseq is one
// participant. Any conforming tool that speaks EDN and SQLite is a peer.
//
// Thread safety: emit() is protected by an internal mutex. Read methods
// rely on SQLite's serialised threading mode for concurrent access through
// the same connection. Do not share a log instance across processes.
// ---------------------------------------------------------------------------

namespace txlog {

// ---------------------------------------------------------------------------
// source — named constants for format-owned vocabulary.
//
// EDN keyword namespace convention:
//   :txlog/<name>       format-owned; every txlog-aware tool should understand
//   :org.cljseq/<name>  cljseq-specific; opaque-but-valid to non-cljseq tools
//   :<org>/<name>       open extension; any participant uses their own ns
// ---------------------------------------------------------------------------

namespace source {
    inline const edn::keyword user{"txlog/user"};     // Direct user action
    inline const edn::keyword schema{"txlog/schema"}; // Schema initialisation
    inline const edn::keyword error{"txlog/error"};   // Error recovery
    inline const edn::keyword undo{"txlog/undo"};     // Undo operation
} // namespace source

// ---------------------------------------------------------------------------
// entry — one row from the changes table.
// ---------------------------------------------------------------------------

struct entry {
    edn::uuid                 id;         // 16-byte UUID; caller assigns before emit
    double                    beat;       // musical time
    int64_t                   wall_ns;    // wall-clock nanoseconds (POSIX epoch)
    edn::keyword              source{""}; // e.g. :txlog/user, :org.cljseq/loop; set before emit
    edn::value                path;       // always edn::vector of edn::keyword in practice
    std::optional<edn::value> before;     // EDN value before the change; absent on insert
    std::optional<edn::value> after;      // EDN value after the change; absent on delete
    std::optional<edn::value> parent;     // causal parent tx_id, if any
};

// ---------------------------------------------------------------------------
// timeline — output of crystallize(): path → [{beat, value}]
//
// Beats are normalised so that beat_from maps to 0.0.
// ---------------------------------------------------------------------------

using beat_value = std::pair<double, edn::value>;
using timeline   = std::map<edn::value, std::vector<beat_value>>;

// ---------------------------------------------------------------------------
// diff_result — output of diff(): final-state comparison of two logs.
// ---------------------------------------------------------------------------

struct diff_result {
    edn::map added;     // {path → value}            in b, absent from a
    edn::map removed;   // {path → value}            in a, absent from b
    edn::map changed;   // {path → {:before :after}} present in both, different
    edn::set unchanged; // paths present in both with identical final value
};

// ---------------------------------------------------------------------------
// log — the primary API.
//
// Open or create a txlog SQLite file. The constructor creates both tables
// and enables WAL mode if they do not already exist.
// ---------------------------------------------------------------------------

class log {
  public:
    // Open or create. db_path may be ":memory:" for an in-process database.
    explicit log(std::string_view db_path);
    ~log();

    log(const log&)            = delete;
    log& operator=(const log&) = delete;
    log(log&&) noexcept;
    log& operator=(log&&) noexcept;

    // -----------------------------------------------------------------------
    // Writer
    // -----------------------------------------------------------------------

    // Register a source kind. Idempotent — safe to call on every open;
    // existing entries are not updated. A source kind should be registered
    // before the first emit() that uses it (asserted in debug builds).
    void register_source(edn::keyword id, std::string_view name, std::string_view description = {});

    // Append one entry. Thread-safe; serialised via internal mutex.
    // path, before, after, parent are serialised to EDN strings.
    // tx_id bytes are stored as a raw 16-byte BLOB.
    void emit(const entry& e);

    // -----------------------------------------------------------------------
    // Layer 1 — full log
    // -----------------------------------------------------------------------

    std::vector<entry> read_all() const;

    // -----------------------------------------------------------------------
    // Layer 2 — query (mirrors cljseq.journal)
    // -----------------------------------------------------------------------

    // All writes to path, in write order.
    std::vector<entry> history(const edn::value& path) const;

    // Value of path at beat — last write at or before that beat.
    std::optional<edn::value> at(const edn::value& path, double beat) const;

    // Writes in [beat_from, beat_to], optionally filtered by source and/or path.
    std::vector<entry> range(double beat_from, double beat_to,
                             std::optional<edn::keyword> source = {},
                             std::optional<edn::value>   path   = {}) const;

    // All writes attributed to a source kind.
    std::vector<entry> by_source(edn::keyword source) const;

    // Set of paths written at least once.
    edn::set active_paths() const;

    // {path → last written value} — final-state fold. Paths whose last
    // write deleted the value (after = nil/absent) are excluded.
    edn::map latest_values() const;

    // -----------------------------------------------------------------------
    // Layer 3 — semantic transforms
    // -----------------------------------------------------------------------

    // Per-path timeline for a beat window. Beats are normalised so that
    // beat_from maps to 0.0. Only entries with a non-null after value are
    // included. include_schema = false (default) excludes paths whose first
    // element is :cljseq/schema.
    timeline crystallize(double beat_from, double beat_to, std::optional<edn::keyword> source = {},
                         bool include_schema = false) const;

  private:
    struct impl;
    std::unique_ptr<impl> impl_;
};

// Compare the final state of two logs.
diff_result diff(const log& a, const log& b);

} // namespace txlog
