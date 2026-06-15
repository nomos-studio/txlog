;; SPDX-License-Identifier: MIT
(ns txlog.core
  "Read and write the txlog SQLite format.

   Entry maps:
     {:id      java.util.UUID
      :beat    double          ; musical or human-scale beat
      :wall-ns long            ; POSIX nanoseconds
      :source  keyword         ; e.g. :txlog/user, :org.nous/loop
      :path    edn-value       ; vector of keywords in practice
      :before  edn-value       ; nil if absent
      :after   edn-value       ; nil if absent
      :parent  edn-value}      ; nil if absent

   Thread safety: emit and register-source are serialised via locking on the
   connection object. Read methods rely on SQLite WAL mode for concurrent
   access through the same connection."
  (:refer-clojure :exclude [range])
  (:require [clojure.edn      :as edn]
            [next.jdbc        :as jdbc]
            [next.jdbc.sql    :as sql])
  (:import [java.nio ByteBuffer]
           [java.util UUID]))

;; ---------------------------------------------------------------------------
;; Internal helpers
;; ---------------------------------------------------------------------------

(defn- uuid->bytes ^bytes [^UUID uuid]
  (let [buf (ByteBuffer/allocate 16)]
    (.putLong buf (.getMostSignificantBits uuid))
    (.putLong buf (.getLeastSignificantBits uuid))
    (.array buf)))

(defn- bytes->uuid [^bytes bs]
  (let [buf (ByteBuffer/wrap bs)]
    (UUID. (.getLong buf) (.getLong buf))))

(defn- serialize [v]
  (when (some? v) (pr-str v)))

(defn- deserialize [s]
  (when s (edn/read-string s)))

(defn- row->entry [row]
  {:id      (some-> (:changes/tx_id row) bytes->uuid)
   :beat    (:changes/beat row)
   :wall-ns (:changes/wall_ns row)
   :source  (edn/read-string (:changes/source row))
   :path    (edn/read-string (:changes/path row))
   :before  (deserialize (:changes/before row))
   :after   (deserialize (:changes/after row))
   :parent  (deserialize (:changes/parent row))})

(def ^:private select-cols
  "SELECT id, tx_id, beat, wall_ns, source, path, before, after, parent FROM changes")

(def ^:private create-sources-sql
  "CREATE TABLE IF NOT EXISTS sources (
     id          TEXT PRIMARY KEY,
     name        TEXT NOT NULL,
     description TEXT
   )")

(def ^:private create-changes-sql
  "CREATE TABLE IF NOT EXISTS changes (
     id      INTEGER PRIMARY KEY AUTOINCREMENT,
     tx_id   BLOB,
     beat    REAL    NOT NULL,
     wall_ns INTEGER NOT NULL,
     source  TEXT    NOT NULL,
     path    TEXT    NOT NULL,
     before  TEXT,
     after   TEXT,
     parent  TEXT
   )")

(defn- schema-path? [path]
  (= (first path) :txlog/schema))

;; ---------------------------------------------------------------------------
;; Log lifecycle
;; ---------------------------------------------------------------------------

(defrecord Log [conn])

(defn open
  "Open or create a txlog at db-path. db-path may be \":memory:\" for an
   in-process database. Creates the schema and enables WAL mode if absent."
  [db-path]
  (let [conn (jdbc/get-connection {:dbtype "sqlite" :dbname db-path})]
    (jdbc/execute! conn ["PRAGMA journal_mode=WAL"])
    (jdbc/execute! conn [create-sources-sql])
    (jdbc/execute! conn [create-changes-sql])
    (->Log conn)))

(defn close
  "Close the database connection."
  [log]
  (.close ^java.sql.Connection (:conn log)))

(defmacro with-log
  "Open a log at db-path, bind it to sym, and close on exit."
  [[sym db-path] & body]
  `(let [~sym (open ~db-path)]
     (try
       ~@body
       (finally
         (close ~sym)))))

;; ---------------------------------------------------------------------------
;; Writer
;; ---------------------------------------------------------------------------

(defn register-source
  "Register a source kind in the sources table. Idempotent — existing entries
   are not updated. Call before the first emit that uses a source kind."
  ([log id name]
   (register-source log id name nil))
  ([log id name description]
   (let [id-str (pr-str id)]
     (locking (:conn log)
       (jdbc/execute! (:conn log)
         ["INSERT OR IGNORE INTO sources (id, name, description) VALUES (?, ?, ?)"
          id-str name description])))))

(defn emit
  "Append one entry to the log. Thread-safe; serialised via locking.
   entry must contain :source, :path, :beat, :wall-ns, :id.
   :before, :after, :parent are optional and may be nil."
  [log entry]
  (let [{:keys [id beat wall-ns source path before after parent]} entry]
    (locking (:conn log)
      (jdbc/execute! (:conn log)
        ["INSERT INTO changes (tx_id, beat, wall_ns, source, path, before, after, parent)
          VALUES (?, ?, ?, ?, ?, ?, ?, ?)"
         (uuid->bytes id)
         (double beat)
         (long wall-ns)
         (pr-str source)
         (pr-str path)
         (serialize before)
         (serialize after)
         (serialize parent)]))))

;; ---------------------------------------------------------------------------
;; Layer 1 — full log
;; ---------------------------------------------------------------------------

(defn read-all
  "Return all entries in write order."
  [log]
  (mapv row->entry
        (jdbc/execute! (:conn log) [(str select-cols " ORDER BY id")])))

;; ---------------------------------------------------------------------------
;; Layer 2 — query
;; ---------------------------------------------------------------------------

(defn history
  "All writes to path, in write order."
  [log path]
  (mapv row->entry
        (jdbc/execute! (:conn log)
          [(str select-cols " WHERE path = ? ORDER BY id") (pr-str path)])))

(defn at
  "Value of path at beat — the after value of the last write at or before beat.
   Returns nil if no write exists at or before that beat."
  [log path beat]
  (some-> (jdbc/execute-one! (:conn log)
            [(str "SELECT after FROM changes"
                  " WHERE path = ? AND beat <= ? AND after IS NOT NULL"
                  " ORDER BY beat DESC, id DESC LIMIT 1")
             (pr-str path) (double beat)])
          :changes/after
          edn/read-string))

(defn range
  "Entries in [beat-from, beat-to], optionally filtered by :source and/or :path."
  [log beat-from beat-to & {:keys [source path]}]
  (let [clauses (cond-> ["beat >= ? AND beat <= ?"]
                  source (conj "source = ?")
                  path   (conj "path = ?"))
        params  (cond-> [(double beat-from) (double beat-to)]
                  source (conj (pr-str source))
                  path   (conj (pr-str path)))
        sql     (str select-cols " WHERE " (clojure.string/join " AND " clauses) " ORDER BY id")]
    (mapv row->entry (jdbc/execute! (:conn log) (into [sql] params)))))

(defn by-source
  "All writes attributed to a source kind, in write order."
  [log source]
  (mapv row->entry
        (jdbc/execute! (:conn log)
          [(str select-cols " WHERE source = ? ORDER BY id") (pr-str source)])))

(defn active-paths
  "Set of paths written at least once."
  [log]
  (into #{}
        (map (comp edn/read-string :changes/path))
        (jdbc/execute! (:conn log) ["SELECT DISTINCT path FROM changes"])))

(defn latest-values
  "Map of path → last written value. Excludes paths whose last write had no
   after value (deletions)."
  [log]
  (into {}
        (map (fn [row] [(edn/read-string (:changes/path row))
                        (edn/read-string (:changes/after row))]))
        (jdbc/execute! (:conn log)
          ["SELECT c.path, c.after FROM changes c
            INNER JOIN (SELECT path, MAX(id) AS max_id FROM changes GROUP BY path) latest
              ON c.path = latest.path AND c.id = latest.max_id
            WHERE c.after IS NOT NULL"])))

;; ---------------------------------------------------------------------------
;; Layer 3 — semantic transforms
;; ---------------------------------------------------------------------------

(defn crystallize
  "Per-path timeline for a beat window. Beats are normalised to beat-from = 0.
   Only entries with a non-nil after value are included.
   :include-schema? false (default) excludes paths starting with :txlog/schema."
  [log beat-from beat-to & {:keys [source include-schema?] :or {include-schema? false}}]
  (let [entries (apply range log beat-from beat-to
                       (when source [:source source]))]
    (reduce (fn [tl {:keys [path beat after]}]
              (if (or (nil? after)
                      (and (not include-schema?) (schema-path? path)))
                tl
                (update tl path (fnil conj [])
                        {:beat (- beat beat-from) :value after})))
            {}
            entries)))

;; ---------------------------------------------------------------------------
;; Merge + diff
;; ---------------------------------------------------------------------------

(defn merge-into
  "Merge entries from src log into dst log. Re-orders by wall-ns. Unions
   sources via register-source (idempotent). Returns dst."
  [dst src]
  (doseq [row (jdbc/execute! (:conn src)
                ["SELECT id, name, description FROM sources"])]
    (register-source dst
                     (edn/read-string (:sources/id row))
                     (:sources/name row)
                     (:sources/description row)))
  (doseq [entry (sort-by :wall-ns (read-all src))]
    (emit dst entry))
  dst)

(defn diff
  "Compare the final state of two logs.
   Returns {:added {path val} :removed {path val}
            :changed {path {:before old :after new}}
            :unchanged #{path}}."
  [log-a log-b]
  (let [a (latest-values log-a)
        b (latest-values log-b)]
    {:added     (into {} (remove (fn [[k _]] (contains? a k))) b)
     :removed   (into {} (remove (fn [[k _]] (contains? b k))) a)
     :changed   (into {} (for [[k bv] b
                               :let  [av (get a k)]
                               :when (and av (not= av bv))]
                           [k {:before av :after bv}]))
     :unchanged (into #{} (for [[k bv] b
                                :let  [av (get a k)]
                                :when (and av (= av bv))]
                            k))}))
