; SPDX-License-Identifier: MIT
(in-package #:txlog)

;; ---------------------------------------------------------------------------
;; Schema SQL
;; ---------------------------------------------------------------------------

(defparameter +wal-pragma+
  "PRAGMA journal_mode=WAL")

(defparameter +create-sources+
  "CREATE TABLE IF NOT EXISTS sources (
     id          TEXT PRIMARY KEY,
     name        TEXT NOT NULL,
     description TEXT
   )")

(defparameter +create-changes+
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

(defparameter +select-cols+
  "SELECT id, tx_id, beat, wall_ns, source, path, before, after, parent FROM changes")

;; ---------------------------------------------------------------------------
;; UUID ↔ bytes
;;
;; tx_id is stored as a raw 16-byte BLOB, not as a #uuid EDN string.
;; Byte order: big-endian, matching edn-cpp's edn::uuid and java.util.UUID.
;; Use a (vector (unsigned-byte 8) 16) in CL.
;; ---------------------------------------------------------------------------

(defun uuid-string->bytes (uuid-string)
  "Parse canonical UUID string to a 16-element (unsigned-byte 8) vector. STUB."
  (declare (ignore uuid-string))
  (error "uuid-string->bytes: not yet implemented"))

(defun bytes->uuid-string (bytes)
  "Format a 16-element byte vector as a canonical UUID string. STUB."
  (declare (ignore bytes))
  (error "bytes->uuid-string: not yet implemented"))

;; ---------------------------------------------------------------------------
;; Entry plist
;;
;; Entries are plain property lists:
;;   (:id "xxxxxxxx-xxxx-..." :beat 1.0 :wall-ns 1714000000000000000
;;    :source <edn-keyword> :path (<edn-keyword> ...)
;;    :before <value-or-nil> :after <value-or-nil> :parent <value-or-nil>)
;;
;; :id is a UUID string; :source is an edn-keyword; :path is a list of
;; edn-keywords; :before/:after/:parent are arbitrary EDN values or nil.
;; ---------------------------------------------------------------------------

(defun row->entry (row)
  "Convert a cl-sqlite result row to an entry plist. STUB."
  (declare (ignore row))
  (error "row->entry: not yet implemented"))

;; ---------------------------------------------------------------------------
;; log struct
;; ---------------------------------------------------------------------------

(defstruct (log (:constructor %make-log)
                (:predicate log-p))
  db            ; cl-sqlite database handle
  (lock (bt:make-lock "txlog-write-lock") :read-only t))

;; ---------------------------------------------------------------------------
;; Lifecycle
;; ---------------------------------------------------------------------------

(defun open (db-path)
  "Open or create a txlog at DB-PATH. Creates the schema and enables WAL mode.
   DB-PATH may be \":memory:\" for an in-process database."
  (let* ((db  (sqlite:connect db-path))
         (log (%make-log :db db)))
    (sqlite:execute-non-query db +wal-pragma+)
    (sqlite:execute-non-query db +create-sources+)
    (sqlite:execute-non-query db +create-changes+)
    log))

(defun close (log)
  "Close the database connection."
  (sqlite:disconnect (log-db log)))

(defmacro with-log ((var db-path) &body body)
  "Open a log at DB-PATH, bind it to VAR, and close on exit."
  `(let ((,var (open ,db-path)))
     (unwind-protect
          (progn ,@body)
       (close ,var))))

;; ---------------------------------------------------------------------------
;; Writer
;; ---------------------------------------------------------------------------

(defun register-source (log id name &optional description)
  "Register a source kind. Idempotent — existing entries are not updated.
   ID is an edn-keyword, e.g. txlog.source:+user+."
  (bt:with-lock-held ((log-lock log))
    (sqlite:execute-non-query
     (log-db log)
     "INSERT OR IGNORE INTO sources (id, name, description) VALUES (?, ?, ?)"
     (txlog.edn:to-edn-string id)
     name
     description)))

(defun emit (log entry)
  "Append one entry to the log. Thread-safe; serialised via lock.
   ENTRY is a plist with :id :beat :wall-ns :source :path
   and optional :before :after :parent."
  (bt:with-lock-held ((log-lock log))
    (sqlite:execute-non-query
     (log-db log)
     "INSERT INTO changes (tx_id, beat, wall_ns, source, path, before, after, parent)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?)"
     (uuid-string->bytes (getf entry :id))
     (float (getf entry :beat) 1.0d0)
     (getf entry :wall-ns)
     (txlog.edn:to-edn-string (getf entry :source))
     (txlog.edn:to-edn-string (getf entry :path))
     (let ((v (getf entry :before))) (when v (txlog.edn:to-edn-string v)))
     (let ((v (getf entry :after)))  (when v (txlog.edn:to-edn-string v)))
     (let ((v (getf entry :parent))) (when v (txlog.edn:to-edn-string v))))))

;; ---------------------------------------------------------------------------
;; Layer 1 — full log
;; ---------------------------------------------------------------------------

(defun read-all (log)
  "Return all entries in write order. STUB — implement row->entry."
  (mapcar #'row->entry
          (sqlite:execute-to-list
           (log-db log)
           (concatenate 'string +select-cols+ " ORDER BY id"))))

;; ---------------------------------------------------------------------------
;; Layer 2 — query
;; ---------------------------------------------------------------------------

(defun history (log path)
  "All writes to PATH in write order."
  (mapcar #'row->entry
          (sqlite:execute-to-list
           (log-db log)
           (concatenate 'string +select-cols+ " WHERE path = ? ORDER BY id")
           (txlog.edn:to-edn-string path))))

(defun at (log path beat)
  "Value of PATH at BEAT — last after value at or before that beat.
   Returns nil if no write exists at or before that beat."
  (let ((row (sqlite:execute-one-row-m-v
              (log-db log)
              "SELECT after FROM changes
               WHERE path = ? AND beat <= ? AND after IS NOT NULL
               ORDER BY beat DESC, id DESC LIMIT 1"
              (txlog.edn:to-edn-string path)
              (float beat 1.0d0))))
    (when row
      (txlog.edn:from-edn-string row))))

(defun range (log beat-from beat-to &key source path)
  "Entries in [BEAT-FROM, BEAT-TO], optionally filtered by :SOURCE and/or :PATH."
  (let* ((clauses (list "beat >= ? AND beat <= ?"))
         (params  (list (float beat-from 1.0d0) (float beat-to 1.0d0))))
    (when source
      (push "source = ?" clauses)
      (setf params (append params (list (txlog.edn:to-edn-string source)))))
    (when path
      (push "path = ?" clauses)
      (setf params (append params (list (txlog.edn:to-edn-string path)))))
    (let ((sql (format nil "~a WHERE ~a ORDER BY id"
                       +select-cols+
                       (format nil "~{~a~^ AND ~}" (reverse clauses)))))
      (mapcar #'row->entry
              (apply #'sqlite:execute-to-list (log-db log) sql params)))))

(defun by-source (log source)
  "All writes attributed to SOURCE in write order."
  (mapcar #'row->entry
          (sqlite:execute-to-list
           (log-db log)
           (concatenate 'string +select-cols+ " WHERE source = ? ORDER BY id")
           (txlog.edn:to-edn-string source))))

(defun active-paths (log)
  "List of distinct paths written at least once."
  (mapcar (lambda (row) (txlog.edn:from-edn-string (first row)))
          (sqlite:execute-to-list
           (log-db log)
           "SELECT DISTINCT path FROM changes")))

(defun latest-values (log)
  "Alist of (path . value) for the last written value of each path.
   Excludes paths whose last write had no after value (deletions)."
  (mapcar (lambda (row)
            (cons (txlog.edn:from-edn-string (first row))
                  (txlog.edn:from-edn-string (second row))))
          (sqlite:execute-to-list
           (log-db log)
           "SELECT c.path, c.after FROM changes c
            INNER JOIN (SELECT path, MAX(id) AS max_id FROM changes GROUP BY path) latest
              ON c.path = latest.path AND c.id = latest.max_id
            WHERE c.after IS NOT NULL")))

;; ---------------------------------------------------------------------------
;; Layer 3 — semantic transforms
;; ---------------------------------------------------------------------------

(defun crystallize (log beat-from beat-to &key source (include-schema nil))
  "Per-path timeline for a beat window. Beats normalised to BEAT-FROM = 0.
   Only entries with a non-nil after value are included.
   :INCLUDE-SCHEMA nil (default) excludes paths starting with :cljseq/schema."
  (let ((entries (range log beat-from beat-to :source source))
        (result  (make-hash-table :test 'equal)))
    (dolist (e entries)
      (let ((path  (getf e :path))
            (after (getf e :after))
            (beat  (getf e :beat)))
        (when (and after
                   (or include-schema
                       (not (edn-schema-path-p path))))
          (push (list :beat (- beat beat-from) :value after)
                (gethash path result)))))
    ;; Reverse each path's list (push builds it in reverse order)
    (maphash (lambda (k v) (setf (gethash k result) (nreverse v))) result)
    result))

(defun edn-schema-path-p (path)
  "True if PATH starts with the :cljseq/schema keyword."
  (and (consp path)
       (txlog.edn:edn-keyword-p (first path))
       (string= (txlog.edn:edn-keyword-name (first path)) "cljseq/schema")))

;; ---------------------------------------------------------------------------
;; Merge + diff
;; ---------------------------------------------------------------------------

(defstruct diff-result
  added      ; alist (path . value)    — in b, absent from a
  removed    ; alist (path . value)    — in a, absent from b
  changed    ; alist (path . (:before old :after new)) — different
  unchanged) ; list of paths          — present in both, same value

(defun merge-into (dst src)
  "Merge entries from SRC log into DST log, ordered by wall-ns.
   Unions sources via register-source (idempotent). Returns DST."
  (dolist (row (sqlite:execute-to-list
                (log-db src)
                "SELECT id, name, description FROM sources"))
    (register-source dst
                     (txlog.edn:from-edn-string (first row))
                     (second row)
                     (third row)))
  (dolist (entry (sort (read-all src) #'< :key (lambda (e) (getf e :wall-ns))))
    (emit dst entry))
  dst)

(defun diff (log-a log-b)
  "Compare the final state of two logs. Returns a DIFF-RESULT."
  (let ((a (latest-values log-a))
        (b (latest-values log-b)))
    (make-diff-result
     :added     (loop for (k . bv) in b
                      unless (assoc k a :test #'equal) collect (cons k bv))
     :removed   (loop for (k . av) in a
                      unless (assoc k b :test #'equal) collect (cons k av))
     :changed   (loop for (k . bv) in b
                      for av = (cdr (assoc k a :test #'equal))
                      when (and av (not (equal av bv)))
                        collect (cons k (list :before av :after bv)))
     :unchanged (loop for (k . bv) in b
                      for av = (cdr (assoc k a :test #'equal))
                      when (and av (equal av bv)) collect k))))
