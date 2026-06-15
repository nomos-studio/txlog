// SPDX-License-Identifier: MIT
#include <txlog/txlog.hpp>

#include <edn/emitter.hpp>
#include <edn/parser.hpp>

#include <sqlite3.h>

#include <cassert>
#include <cstring>
#include <functional>
#include <mutex>
#include <stdexcept>
#include <string>

namespace txlog {

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

namespace {

    edn::parser_opts make_parser_opts() {
        edn::parser_opts opts;
        edn::builtins::register_all(opts);
        return opts;
    }

    // Process-wide parser options with #uuid and #inst handlers registered.
    const edn::parser_opts g_parser_opts = make_parser_opts();

    std::string_view col_text_sv(sqlite3_stmt* stmt, int col) {
        const auto* text = sqlite3_column_text(stmt, col);
        const int   len  = sqlite3_column_bytes(stmt, col);
        return {reinterpret_cast<const char*>(text), static_cast<std::size_t>(len)};
    }

    // Parse an EDN string stored in a column. Throws on parse failure.
    edn::value parse_col(sqlite3_stmt* stmt, int col) {
        auto sv = col_text_sv(stmt, col);
        auto r  = edn::parse(sv, g_parser_opts);
        if (!r) {
            throw std::runtime_error(std::string("txlog: EDN parse error: ") + r.error().message);
        }
        return *r;
    }

    // Parse an EDN keyword stored as ":ns/name" text. Throws on failure.
    edn::keyword parse_keyword_col(sqlite3_stmt* stmt, int col) {
        auto r = edn::parse(col_text_sv(stmt, col), g_parser_opts);
        if (!r || !r->is<edn::keyword>()) {
            throw std::runtime_error("txlog: expected keyword in column");
        }
        return r->get<edn::keyword>();
    }

    bool is_schema_path(const edn::value& path) {
        if (!path.is<edn::vector>())
            return false;
        const auto& items = path.get<edn::vector>().items;
        if (items.empty())
            return false;
        if (!items[0].is<edn::keyword>())
            return false;
        return items[0].get<edn::keyword>().name == "txlog/schema";
    }

} // namespace

// ---------------------------------------------------------------------------
// log::impl — SQLite connection + write mutex
// ---------------------------------------------------------------------------

struct log::impl {
    sqlite3*   db{nullptr};
    std::mutex write_mutex;

    impl() = default;

    ~impl() {
        if (db) {
            sqlite3_close(db);
            db = nullptr;
        }
    }

    impl(const impl&)            = delete;
    impl& operator=(const impl&) = delete;

    void open(std::string_view db_path) {
        std::string path(db_path);
        const int   rc = sqlite3_open(path.c_str(), &db);
        if (rc != SQLITE_OK) {
            std::string msg = db ? sqlite3_errmsg(db) : "sqlite3_open failed";
            sqlite3_close(db);
            db = nullptr;
            throw std::runtime_error("txlog: failed to open database: " + msg);
        }
        exec("PRAGMA journal_mode=WAL;");
        exec(R"sql(
            CREATE TABLE IF NOT EXISTS sources (
                id          TEXT PRIMARY KEY,
                name        TEXT NOT NULL,
                description TEXT
            );
            CREATE TABLE IF NOT EXISTS changes (
                id      INTEGER PRIMARY KEY AUTOINCREMENT,
                tx_id   BLOB,
                beat    REAL    NOT NULL,
                wall_ns INTEGER NOT NULL,
                source  TEXT    NOT NULL,
                path    TEXT    NOT NULL,
                before  TEXT,
                after   TEXT,
                parent  TEXT
            );
        )sql");
    }

    void exec(const char* sql) {
        char*     errmsg = nullptr;
        const int rc     = sqlite3_exec(db, sql, nullptr, nullptr, &errmsg);
        if (rc != SQLITE_OK) {
            std::string msg = errmsg ? errmsg : "unknown error";
            sqlite3_free(errmsg);
            throw std::runtime_error(std::string("txlog: SQL error: ") + msg);
        }
    }

    // Build an entry from the current row of a prepared statement.
    // Column order: 0=id, 1=tx_id, 2=beat, 3=wall_ns, 4=source,
    //               5=path, 6=before, 7=after, 8=parent
    entry row_to_entry(sqlite3_stmt* stmt) const {
        entry e;

        // tx_id — 16-byte BLOB
        const void* blob     = sqlite3_column_blob(stmt, 1);
        const int   blob_len = sqlite3_column_bytes(stmt, 1);
        if (blob && blob_len == 16) {
            std::memcpy(e.id.bytes.data(), blob, 16);
        }

        e.beat    = sqlite3_column_double(stmt, 2);
        e.wall_ns = sqlite3_column_int64(stmt, 3);
        e.source  = parse_keyword_col(stmt, 4);
        e.path    = parse_col(stmt, 5);

        if (sqlite3_column_type(stmt, 6) != SQLITE_NULL) {
            e.before = parse_col(stmt, 6);
        }
        if (sqlite3_column_type(stmt, 7) != SQLITE_NULL) {
            e.after = parse_col(stmt, 7);
        }
        if (sqlite3_column_type(stmt, 8) != SQLITE_NULL) {
            e.parent = parse_col(stmt, 8);
        }

        return e;
    }

    // Execute a SELECT and collect all rows as entries.
    std::vector<entry> select_entries(const char*                        sql,
                                      std::function<void(sqlite3_stmt*)> bind = {}) const {
        sqlite3_stmt* stmt = nullptr;
        if (sqlite3_prepare_v2(db, sql, -1, &stmt, nullptr) != SQLITE_OK) {
            throw std::runtime_error(std::string("txlog: prepare failed: ") + sqlite3_errmsg(db));
        }

        if (bind)
            bind(stmt);

        std::vector<entry> result;
        int                rc;
        while ((rc = sqlite3_step(stmt)) == SQLITE_ROW) {
            result.push_back(row_to_entry(stmt));
        }
        sqlite3_finalize(stmt);

        if (rc != SQLITE_DONE) {
            throw std::runtime_error(std::string("txlog: query step failed: ") +
                                     sqlite3_errmsg(db));
        }
        return result;
    }

    bool source_is_registered(const edn::keyword& kw) const {
        static const char* sql = "SELECT 1 FROM sources WHERE id = ? LIMIT 1";
        sqlite3_stmt*      stmt{nullptr};
        sqlite3_prepare_v2(db, sql, -1, &stmt, nullptr);
        const std::string kw_str = kw.to_string();
        sqlite3_bind_text(stmt, 1, kw_str.c_str(), static_cast<int>(kw_str.size()), SQLITE_STATIC);
        const bool found = (sqlite3_step(stmt) == SQLITE_ROW);
        sqlite3_finalize(stmt);
        return found;
    }
};

// ---------------------------------------------------------------------------
// log — public interface
// ---------------------------------------------------------------------------

log::log(std::string_view db_path) : impl_(std::make_unique<impl>()) {
    impl_->open(db_path);
}

log::~log() = default;

log::log(log&&) noexcept            = default;
log& log::operator=(log&&) noexcept = default;

// ---------------------------------------------------------------------------
// Writer
// ---------------------------------------------------------------------------

void log::register_source(edn::keyword id, std::string_view name, std::string_view description) {
    static const char* sql =
        "INSERT OR IGNORE INTO sources (id, name, description) VALUES (?, ?, ?)";

    const std::string id_str = id.to_string();

    std::lock_guard<std::mutex> lock(impl_->write_mutex);

    sqlite3_stmt* stmt{nullptr};
    if (sqlite3_prepare_v2(impl_->db, sql, -1, &stmt, nullptr) != SQLITE_OK) {
        throw std::runtime_error(std::string("txlog: prepare failed: ") +
                                 sqlite3_errmsg(impl_->db));
    }

    sqlite3_bind_text(stmt, 1, id_str.c_str(), static_cast<int>(id_str.size()), SQLITE_TRANSIENT);
    sqlite3_bind_text(stmt, 2, name.data(), static_cast<int>(name.size()), SQLITE_TRANSIENT);
    if (!description.empty()) {
        sqlite3_bind_text(stmt, 3, description.data(), static_cast<int>(description.size()),
                          SQLITE_TRANSIENT);
    } else {
        sqlite3_bind_null(stmt, 3);
    }

    sqlite3_step(stmt);
    sqlite3_finalize(stmt);
}

void log::emit(const entry& e) {
    static const char* sql =
        "INSERT INTO changes (tx_id, beat, wall_ns, source, path, before, after, parent)"
        " VALUES (?, ?, ?, ?, ?, ?, ?, ?)";

    assert(impl_->source_is_registered(e.source) &&
           "emit(): source must be registered before use (see register_source)");

    const std::string source_str = e.source.to_string();
    const std::string path_str   = edn::to_string(e.path);

    std::lock_guard<std::mutex> lock(impl_->write_mutex);

    sqlite3_stmt* stmt{nullptr};
    if (sqlite3_prepare_v2(impl_->db, sql, -1, &stmt, nullptr) != SQLITE_OK) {
        throw std::runtime_error(std::string("txlog: prepare failed: ") +
                                 sqlite3_errmsg(impl_->db));
    }

    // 1: tx_id BLOB
    sqlite3_bind_blob(stmt, 1, e.id.bytes.data(), static_cast<int>(e.id.bytes.size()),
                      SQLITE_TRANSIENT);
    // 2: beat
    sqlite3_bind_double(stmt, 2, e.beat);
    // 3: wall_ns
    sqlite3_bind_int64(stmt, 3, e.wall_ns);
    // 4: source
    sqlite3_bind_text(stmt, 4, source_str.c_str(), static_cast<int>(source_str.size()),
                      SQLITE_TRANSIENT);
    // 5: path
    sqlite3_bind_text(stmt, 5, path_str.c_str(), static_cast<int>(path_str.size()),
                      SQLITE_TRANSIENT);

    // Helper: bind optional EDN value or NULL
    auto bind_opt = [&](int col, const std::optional<edn::value>& opt) {
        if (opt) {
            const std::string s = edn::to_string(*opt);
            sqlite3_bind_text(stmt, col, s.c_str(), static_cast<int>(s.size()), SQLITE_TRANSIENT);
        } else {
            sqlite3_bind_null(stmt, col);
        }
    };

    bind_opt(6, e.before);
    bind_opt(7, e.after);
    bind_opt(8, e.parent);

    const int rc = sqlite3_step(stmt);
    sqlite3_finalize(stmt);

    if (rc != SQLITE_DONE) {
        throw std::runtime_error(std::string("txlog: emit failed: ") + sqlite3_errmsg(impl_->db));
    }
}

// ---------------------------------------------------------------------------
// Layer 1
// ---------------------------------------------------------------------------

std::vector<entry> log::read_all() const {
    return impl_->select_entries(
        "SELECT id, tx_id, beat, wall_ns, source, path, before, after, parent"
        " FROM changes ORDER BY id");
}

// ---------------------------------------------------------------------------
// Layer 2
// ---------------------------------------------------------------------------

std::vector<entry> log::history(const edn::value& path) const {
    const std::string path_str = edn::to_string(path);
    return impl_->select_entries(
        "SELECT id, tx_id, beat, wall_ns, source, path, before, after, parent"
        " FROM changes WHERE path = ? ORDER BY id",
        [&](sqlite3_stmt* s) {
            sqlite3_bind_text(s, 1, path_str.c_str(), static_cast<int>(path_str.size()),
                              SQLITE_STATIC);
        });
}

std::optional<edn::value> log::at(const edn::value& path, double beat) const {
    static const char* sql = "SELECT after FROM changes"
                             " WHERE path = ? AND beat <= ? AND after IS NOT NULL"
                             " ORDER BY beat DESC, id DESC LIMIT 1";

    const std::string path_str = edn::to_string(path);

    sqlite3_stmt* stmt{nullptr};
    if (sqlite3_prepare_v2(impl_->db, sql, -1, &stmt, nullptr) != SQLITE_OK) {
        throw std::runtime_error(std::string("txlog: prepare failed: ") +
                                 sqlite3_errmsg(impl_->db));
    }

    sqlite3_bind_text(stmt, 1, path_str.c_str(), static_cast<int>(path_str.size()), SQLITE_STATIC);
    sqlite3_bind_double(stmt, 2, beat);

    std::optional<edn::value> result;
    if (sqlite3_step(stmt) == SQLITE_ROW) {
        result = parse_col(stmt, 0);
    }
    sqlite3_finalize(stmt);
    return result;
}

std::vector<entry> log::range(double beat_from, double beat_to, std::optional<edn::keyword> source,
                              std::optional<edn::value> path) const {
    // Build query dynamically based on optional filters.
    std::string sql = "SELECT id, tx_id, beat, wall_ns, source, path, before, after, parent"
                      " FROM changes WHERE beat >= ? AND beat <= ?";

    std::string source_str;
    std::string path_str;

    if (source) {
        sql += " AND source = ?";
        source_str = source->to_string();
    }
    if (path) {
        sql += " AND path = ?";
        path_str = edn::to_string(*path);
    }
    sql += " ORDER BY id";

    return impl_->select_entries(sql.c_str(), [&](sqlite3_stmt* s) {
        sqlite3_bind_double(s, 1, beat_from);
        sqlite3_bind_double(s, 2, beat_to);
        int next = 3;
        if (source) {
            sqlite3_bind_text(s, next++, source_str.c_str(), static_cast<int>(source_str.size()),
                              SQLITE_STATIC);
        }
        if (path) {
            sqlite3_bind_text(s, next++, path_str.c_str(), static_cast<int>(path_str.size()),
                              SQLITE_STATIC);
        }
    });
}

std::vector<entry> log::by_source(edn::keyword src) const {
    const std::string source_str = src.to_string();
    return impl_->select_entries(
        "SELECT id, tx_id, beat, wall_ns, source, path, before, after, parent"
        " FROM changes WHERE source = ? ORDER BY id",
        [&](sqlite3_stmt* s) {
            sqlite3_bind_text(s, 1, source_str.c_str(), static_cast<int>(source_str.size()),
                              SQLITE_STATIC);
        });
}

edn::set log::active_paths() const {
    static const char* sql = "SELECT DISTINCT path FROM changes";

    sqlite3_stmt* stmt{nullptr};
    if (sqlite3_prepare_v2(impl_->db, sql, -1, &stmt, nullptr) != SQLITE_OK) {
        throw std::runtime_error(std::string("txlog: prepare failed: ") +
                                 sqlite3_errmsg(impl_->db));
    }

    edn::set result;
    int      rc;
    while ((rc = sqlite3_step(stmt)) == SQLITE_ROW) {
        result.insert(parse_col(stmt, 0));
    }
    sqlite3_finalize(stmt);

    if (rc != SQLITE_DONE) {
        throw std::runtime_error(std::string("txlog: query step failed: ") +
                                 sqlite3_errmsg(impl_->db));
    }
    return result;
}

edn::map log::latest_values() const {
    // For each path, take the after value of the highest-id row.
    // Exclude rows where after is NULL (deletions).
    static const char* sql =
        "SELECT c.path, c.after FROM changes c"
        " INNER JOIN (SELECT path, MAX(id) AS max_id FROM changes GROUP BY path) latest"
        "   ON c.path = latest.path AND c.id = latest.max_id"
        " WHERE c.after IS NOT NULL";

    sqlite3_stmt* stmt{nullptr};
    if (sqlite3_prepare_v2(impl_->db, sql, -1, &stmt, nullptr) != SQLITE_OK) {
        throw std::runtime_error(std::string("txlog: prepare failed: ") +
                                 sqlite3_errmsg(impl_->db));
    }

    edn::map result;
    int      rc;
    while ((rc = sqlite3_step(stmt)) == SQLITE_ROW) {
        result.insert(parse_col(stmt, 0), parse_col(stmt, 1));
    }
    sqlite3_finalize(stmt);

    if (rc != SQLITE_DONE) {
        throw std::runtime_error(std::string("txlog: query step failed: ") +
                                 sqlite3_errmsg(impl_->db));
    }
    return result;
}

// ---------------------------------------------------------------------------
// Layer 3
// ---------------------------------------------------------------------------

timeline log::crystallize(double beat_from, double beat_to, std::optional<edn::keyword> source,
                          bool include_schema) const {
    const auto entries = range(beat_from, beat_to, source);

    timeline result;
    for (const auto& e : entries) {
        if (!e.after)
            continue;
        if (!include_schema && is_schema_path(e.path))
            continue;
        result[e.path].emplace_back(e.beat - beat_from, *e.after);
    }
    return result;
}

// ---------------------------------------------------------------------------
// diff — compare final state of two logs
// ---------------------------------------------------------------------------

diff_result diff(const log& a, const log& b) {
    const edn::map a_latest = a.latest_values();
    const edn::map b_latest = b.latest_values();

    diff_result result;

    // Walk b: find added and changed
    for (const auto& [key, b_val] : b_latest) {
        const edn::value* a_val = a_latest.find(key);
        if (!a_val) {
            result.added.insert(key, b_val);
        } else if (*a_val != b_val) {
            edn::map change;
            change.insert(edn::keyword{"before"}, *a_val);
            change.insert(edn::keyword{"after"}, b_val);
            result.changed.insert(key, edn::value{std::move(change)});
        } else {
            result.unchanged.insert(key);
        }
    }

    // Walk a: find removed (in a but not in b)
    for (const auto& [key, a_val] : a_latest) {
        if (!b_latest.find(key)) {
            result.removed.insert(key, a_val);
        }
    }

    return result;
}

} // namespace txlog
