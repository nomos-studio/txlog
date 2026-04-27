// SPDX-License-Identifier: MIT
#include <txlog/txlog.hpp>

#include <catch2/catch_approx.hpp>
#include <catch2/catch_test_macros.hpp>

#include <array>
#include <cstdint>

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

namespace {

// Minimal UUID factory for tests — sequential, not random.
edn::uuid make_uuid(uint8_t tag) {
    edn::uuid u;
    u.bytes.fill(tag);
    return u;
}

// Build a path vector keyword from a single keyword name.
edn::value make_path(std::initializer_list<const char*> kws) {
    edn::vector v;
    for (const char* kw : kws) {
        v.items.emplace_back(edn::keyword{kw});
    }
    return edn::value{v};
}

txlog::entry make_entry(uint8_t id_tag, double beat, edn::keyword source, edn::value path,
                        std::optional<edn::value> before, std::optional<edn::value> after) {
    txlog::entry e;
    e.id      = make_uuid(id_tag);
    e.beat    = beat;
    e.wall_ns = static_cast<int64_t>(beat * 1'000'000'000LL);
    e.source  = source;
    e.path    = std::move(path);
    e.before  = std::move(before);
    e.after   = std::move(after);
    return e;
}

} // namespace

// ---------------------------------------------------------------------------
// Schema and registration
// ---------------------------------------------------------------------------

TEST_CASE("log opens and creates schema", "[log]") {
    txlog::log db{":memory:"};
    // If open succeeded without throwing, schema is in place.
    REQUIRE(db.read_all().empty());
}

TEST_CASE("register_source is idempotent", "[log]") {
    txlog::log db{":memory:"};

    db.register_source(txlog::source::user, "User", "Direct user action");
    db.register_source(txlog::source::user, "User", "Direct user action");
    db.register_source(txlog::source::user, "Different description");

    // No exception; calling active_paths doesn't throw either.
    REQUIRE(db.active_paths().empty());
}

// ---------------------------------------------------------------------------
// emit / read_all
// ---------------------------------------------------------------------------

TEST_CASE("emit and read_all round-trip", "[log]") {
    txlog::log db{":memory:"};
    db.register_source(txlog::source::user, "User");

    auto path = make_path({"synth/cutoff"});

    txlog::entry e;
    e.id      = make_uuid(1);
    e.beat    = 1.0;
    e.wall_ns = 1'000'000'000LL;
    e.source  = txlog::source::user;
    e.path    = path;
    e.before  = std::nullopt;
    e.after   = edn::value{0.5};

    db.emit(e);

    const auto rows = db.read_all();
    REQUIRE(rows.size() == 1);

    const auto& r = rows[0];
    REQUIRE(r.id == e.id);
    REQUIRE(r.beat == Catch::Approx(1.0));
    REQUIRE(r.wall_ns == 1'000'000'000LL);
    REQUIRE(r.source == txlog::source::user);
    REQUIRE(r.path == path);
    REQUIRE(!r.before.has_value());
    REQUIRE(r.after.has_value());
    REQUIRE(*r.after == edn::value{0.5});
}

TEST_CASE("emit preserves nullable fields", "[log]") {
    txlog::log db{":memory:"};
    db.register_source(txlog::source::user, "User");

    auto path = make_path({"synth/resonance"});

    txlog::entry e;
    e.id      = make_uuid(2);
    e.beat    = 2.0;
    e.wall_ns = 2'000'000'000LL;
    e.source  = txlog::source::user;
    e.path    = path;
    e.before  = edn::value{0.3};
    e.after   = edn::value{0.7};
    e.parent  = edn::value{edn::keyword{"txlog/schema"}};

    db.emit(e);

    const auto rows = db.read_all();
    REQUIRE(rows.size() == 1);
    REQUIRE(rows[0].before.has_value());
    REQUIRE(*rows[0].before == edn::value{0.3});
    REQUIRE(rows[0].after.has_value());
    REQUIRE(*rows[0].after == edn::value{0.7});
    REQUIRE(rows[0].parent.has_value());
}

TEST_CASE("emit preserves vector path with multiple keywords", "[log]") {
    txlog::log db{":memory:"};
    db.register_source(txlog::source::user, "User");

    auto         path = make_path({"device/hydra", "patch/cutoff"});
    txlog::entry e;
    e.id      = make_uuid(3);
    e.beat    = 3.0;
    e.wall_ns = 0;
    e.source  = txlog::source::user;
    e.path    = path;
    e.after   = edn::value{int64_t{127}};
    db.emit(e);

    const auto rows = db.read_all();
    REQUIRE(rows.size() == 1);
    REQUIRE(rows[0].path == path);
}

// ---------------------------------------------------------------------------
// Layer 2 queries
// ---------------------------------------------------------------------------

TEST_CASE("history returns entries for a path in write order", "[log]") {
    txlog::log db{":memory:"};
    db.register_source(txlog::source::user, "User");

    auto path  = make_path({"synth/cutoff"});
    auto other = make_path({"synth/volume"});

    db.emit(make_entry(1, 1.0, txlog::source::user, path, {}, edn::value{0.1}));
    db.emit(make_entry(2, 2.0, txlog::source::user, other, {}, edn::value{0.5}));
    db.emit(make_entry(3, 3.0, txlog::source::user, path, edn::value{0.1}, edn::value{0.9}));

    const auto hist = db.history(path);
    REQUIRE(hist.size() == 2);
    REQUIRE(*hist[0].after == edn::value{0.1});
    REQUIRE(*hist[1].after == edn::value{0.9});
}

TEST_CASE("at returns last value at or before beat", "[log]") {
    txlog::log db{":memory:"};
    db.register_source(txlog::source::user, "User");

    auto path = make_path({"synth/cutoff"});
    db.emit(make_entry(1, 1.0, txlog::source::user, path, {}, edn::value{0.2}));
    db.emit(make_entry(2, 3.0, txlog::source::user, path, edn::value{0.2}, edn::value{0.8}));

    REQUIRE(!db.at(path, 0.5).has_value());         // before any write
    REQUIRE(*db.at(path, 1.0) == edn::value{0.2});  // exact beat
    REQUIRE(*db.at(path, 2.0) == edn::value{0.2});  // between writes
    REQUIRE(*db.at(path, 3.0) == edn::value{0.8});  // second write
    REQUIRE(*db.at(path, 99.0) == edn::value{0.8}); // after last write
}

TEST_CASE("range filters by beat window", "[log]") {
    txlog::log db{":memory:"};
    db.register_source(txlog::source::user, "User");

    auto path = make_path({"synth/cutoff"});
    db.emit(make_entry(1, 1.0, txlog::source::user, path, {}, edn::value{0.1}));
    db.emit(make_entry(2, 2.0, txlog::source::user, path, {}, edn::value{0.2}));
    db.emit(make_entry(3, 3.0, txlog::source::user, path, {}, edn::value{0.3}));
    db.emit(make_entry(4, 4.0, txlog::source::user, path, {}, edn::value{0.4}));

    const auto window = db.range(2.0, 3.0);
    REQUIRE(window.size() == 2);
    REQUIRE(*window[0].after == edn::value{0.2});
    REQUIRE(*window[1].after == edn::value{0.3});
}

TEST_CASE("range filters by source and path", "[log]") {
    txlog::log db{":memory:"};
    db.register_source(txlog::source::user, "User");
    db.register_source(txlog::source::schema, "Schema");

    auto path_a = make_path({"synth/cutoff"});
    auto path_b = make_path({"synth/volume"});

    db.emit(make_entry(1, 1.0, txlog::source::user, path_a, {}, edn::value{0.1}));
    db.emit(make_entry(2, 2.0, txlog::source::schema, path_a, {}, edn::value{0.2}));
    db.emit(make_entry(3, 3.0, txlog::source::user, path_b, {}, edn::value{0.3}));

    SECTION("filter by source") {
        const auto r = db.range(0.0, 10.0, txlog::source::user);
        REQUIRE(r.size() == 2);
    }

    SECTION("filter by path") {
        const auto r = db.range(0.0, 10.0, {}, path_a);
        REQUIRE(r.size() == 2);
    }

    SECTION("filter by source and path") {
        const auto r = db.range(0.0, 10.0, txlog::source::user, path_a);
        REQUIRE(r.size() == 1);
        REQUIRE(*r[0].after == edn::value{0.1});
    }
}

TEST_CASE("by_source returns entries for that source", "[log]") {
    txlog::log db{":memory:"};
    db.register_source(txlog::source::user, "User");
    db.register_source(txlog::source::schema, "Schema");

    auto path = make_path({"synth/cutoff"});
    db.emit(make_entry(1, 1.0, txlog::source::user, path, {}, edn::value{0.1}));
    db.emit(make_entry(2, 2.0, txlog::source::schema, path, {}, edn::value{0.2}));
    db.emit(make_entry(3, 3.0, txlog::source::user, path, {}, edn::value{0.3}));

    const auto user_entries = db.by_source(txlog::source::user);
    REQUIRE(user_entries.size() == 2);

    const auto schema_entries = db.by_source(txlog::source::schema);
    REQUIRE(schema_entries.size() == 1);
}

TEST_CASE("active_paths returns distinct paths", "[log]") {
    txlog::log db{":memory:"};
    db.register_source(txlog::source::user, "User");

    auto path_a = make_path({"synth/cutoff"});
    auto path_b = make_path({"synth/volume"});

    db.emit(make_entry(1, 1.0, txlog::source::user, path_a, {}, edn::value{0.1}));
    db.emit(make_entry(2, 2.0, txlog::source::user, path_a, {}, edn::value{0.2}));
    db.emit(make_entry(3, 3.0, txlog::source::user, path_b, {}, edn::value{0.5}));

    const auto paths = db.active_paths();
    REQUIRE(paths.size() == 2);
    REQUIRE(paths.contains(path_a));
    REQUIRE(paths.contains(path_b));
}

TEST_CASE("latest_values folds to final state", "[log]") {
    txlog::log db{":memory:"};
    db.register_source(txlog::source::user, "User");

    auto path_a = make_path({"synth/cutoff"});
    auto path_b = make_path({"synth/volume"});

    db.emit(make_entry(1, 1.0, txlog::source::user, path_a, {}, edn::value{0.1}));
    db.emit(make_entry(2, 2.0, txlog::source::user, path_a, edn::value{0.1}, edn::value{0.9}));
    db.emit(make_entry(3, 3.0, txlog::source::user, path_b, {}, edn::value{0.5}));

    const auto latest = db.latest_values();
    REQUIRE(latest.size() == 2);
    REQUIRE(*latest.find(path_a) == edn::value{0.9});
    REQUIRE(*latest.find(path_b) == edn::value{0.5});
}

TEST_CASE("latest_values excludes deleted paths", "[log]") {
    txlog::log db{":memory:"};
    db.register_source(txlog::source::user, "User");

    auto path = make_path({"synth/cutoff"});
    db.emit(make_entry(1, 1.0, txlog::source::user, path, {}, edn::value{0.5}));
    // Deletion: after is absent
    {
        txlog::entry del;
        del.id      = make_uuid(2);
        del.beat    = 2.0;
        del.wall_ns = 0;
        del.source  = txlog::source::user;
        del.path    = path;
        del.before  = edn::value{0.5};
        // del.after intentionally absent
        db.emit(del);
    }

    const auto latest = db.latest_values();
    REQUIRE(latest.empty());
}

// ---------------------------------------------------------------------------
// Layer 3 — crystallize
// ---------------------------------------------------------------------------

TEST_CASE("crystallize normalises beats to beat_from", "[log]") {
    txlog::log db{":memory:"};
    db.register_source(txlog::source::user, "User");

    auto path = make_path({"synth/cutoff"});
    db.emit(make_entry(1, 2.0, txlog::source::user, path, {}, edn::value{0.2}));
    db.emit(make_entry(2, 4.0, txlog::source::user, path, {}, edn::value{0.4}));
    db.emit(make_entry(3, 6.0, txlog::source::user, path, {}, edn::value{0.6}));

    const auto tl = db.crystallize(2.0, 5.0);
    REQUIRE(tl.count(path) == 1);

    const auto& bvs = tl.at(path);
    REQUIRE(bvs.size() == 2); // beats 2.0 and 4.0 are in [2.0, 5.0]
    REQUIRE(bvs[0].first == Catch::Approx(0.0));
    REQUIRE(bvs[1].first == Catch::Approx(2.0));
}

TEST_CASE("crystallize excludes schema paths by default", "[log]") {
    txlog::log db{":memory:"};
    db.register_source(txlog::source::user, "User");
    db.register_source(txlog::source::schema, "Schema");

    auto schema_path = make_path({"cljseq/schema", "some-key"});
    auto data_path   = make_path({"synth/cutoff"});

    db.emit(make_entry(1, 1.0, txlog::source::schema, schema_path, {}, edn::value{true}));
    db.emit(make_entry(2, 2.0, txlog::source::user, data_path, {}, edn::value{0.5}));

    SECTION("schema excluded by default") {
        const auto tl = db.crystallize(0.0, 10.0);
        REQUIRE(tl.count(schema_path) == 0);
        REQUIRE(tl.count(data_path) == 1);
    }

    SECTION("schema included when requested") {
        const auto tl = db.crystallize(0.0, 10.0, {}, true);
        REQUIRE(tl.count(schema_path) == 1);
        REQUIRE(tl.count(data_path) == 1);
    }
}

TEST_CASE("crystallize excludes entries without after value", "[log]") {
    txlog::log db{":memory:"};
    db.register_source(txlog::source::user, "User");

    auto path = make_path({"synth/cutoff"});
    db.emit(make_entry(1, 1.0, txlog::source::user, path, {}, edn::value{0.5}));
    // deletion entry — no after
    {
        txlog::entry del;
        del.id      = make_uuid(2);
        del.beat    = 2.0;
        del.wall_ns = 0;
        del.source  = txlog::source::user;
        del.path    = path;
        del.before  = edn::value{0.5};
        db.emit(del);
    }

    const auto tl = db.crystallize(0.0, 10.0);
    REQUIRE(tl.count(path) == 1);
    REQUIRE(tl.at(path).size() == 1); // only the first (non-deletion) entry
}

// ---------------------------------------------------------------------------
// diff
// ---------------------------------------------------------------------------

TEST_CASE("diff identifies added, removed, changed, unchanged", "[diff]") {
    txlog::log a{":memory:"};
    txlog::log b{":memory:"};

    a.register_source(txlog::source::user, "User");
    b.register_source(txlog::source::user, "User");

    auto path_shared  = make_path({"shared/key"});
    auto path_changed = make_path({"changed/key"});
    auto path_removed = make_path({"removed/key"});
    auto path_added   = make_path({"added/key"});

    // a: shared(1.0), changed(old), removed(0.5)
    a.emit(make_entry(1, 1.0, txlog::source::user, path_shared, {}, edn::value{1.0}));
    a.emit(make_entry(2, 1.0, txlog::source::user, path_changed, {}, edn::value{int64_t{10}}));
    a.emit(make_entry(3, 1.0, txlog::source::user, path_removed, {}, edn::value{0.5}));

    // b: shared(1.0), changed(new), added(99)
    b.emit(make_entry(1, 1.0, txlog::source::user, path_shared, {}, edn::value{1.0}));
    b.emit(make_entry(2, 1.0, txlog::source::user, path_changed, {}, edn::value{int64_t{20}}));
    b.emit(make_entry(4, 1.0, txlog::source::user, path_added, {}, edn::value{int64_t{99}}));

    const auto result = diff(a, b);

    REQUIRE(result.added.size() == 1);
    REQUIRE(result.added.find(path_added) != nullptr);

    REQUIRE(result.removed.size() == 1);
    REQUIRE(result.removed.find(path_removed) != nullptr);

    REQUIRE(result.changed.size() == 1);
    REQUIRE(result.changed.find(path_changed) != nullptr);

    REQUIRE(result.unchanged.size() == 1);
    REQUIRE(result.unchanged.contains(path_shared));
}

TEST_CASE("diff on identical logs produces only unchanged", "[diff]") {
    txlog::log a{":memory:"};
    txlog::log b{":memory:"};

    a.register_source(txlog::source::user, "User");
    b.register_source(txlog::source::user, "User");

    auto path = make_path({"synth/cutoff"});
    a.emit(make_entry(1, 1.0, txlog::source::user, path, {}, edn::value{0.5}));
    b.emit(make_entry(2, 1.0, txlog::source::user, path, {}, edn::value{0.5}));

    const auto result = diff(a, b);
    REQUIRE(result.added.empty());
    REQUIRE(result.removed.empty());
    REQUIRE(result.changed.empty());
    REQUIRE(result.unchanged.size() == 1);
}

TEST_CASE("diff on empty logs is all-empty", "[diff]") {
    txlog::log a{":memory:"};
    txlog::log b{":memory:"};

    const auto result = diff(a, b);
    REQUIRE(result.added.empty());
    REQUIRE(result.removed.empty());
    REQUIRE(result.changed.empty());
    REQUIRE(result.unchanged.empty());
}

// ---------------------------------------------------------------------------
// Move semantics
// ---------------------------------------------------------------------------

TEST_CASE("log is movable", "[log]") {
    txlog::log a{":memory:"};
    a.register_source(txlog::source::user, "User");
    auto path = make_path({"synth/cutoff"});
    a.emit(make_entry(1, 1.0, txlog::source::user, path, {}, edn::value{0.5}));

    txlog::log b    = std::move(a);
    const auto rows = b.read_all();
    REQUIRE(rows.size() == 1);
}
