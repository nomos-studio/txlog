; SPDX-License-Identifier: MIT
(defpackage #:txlog/test
  (:use #:cl #:fiveam #:txlog #:txlog.edn)
  (:shadowing-import-from #:txlog #:close #:log #:open))

(in-package #:txlog/test)

;; ---------------------------------------------------------------------------
;; Test suite
;; ---------------------------------------------------------------------------

(def-suite txlog-suite :description "txlog library tests")
(in-suite txlog-suite)

;; ---------------------------------------------------------------------------
;; Helpers
;; ---------------------------------------------------------------------------

(defun kw (name)
  "Shorthand: (kw \"txlog/user\") → edn-keyword."
  (make-edn-keyword :name name))

(defun make-path (&rest names)
  "Build an EDN path as a list of edn-keywords."
  (mapcar #'kw names))

(defun make-entry (&key (id "00000000-0000-0000-0000-000000000001")
                        (beat 1.0d0)
                        (wall-ns 1714000000000000000)
                        (source (kw "txlog/user"))
                        (path (make-path "test/value"))
                        before after parent)
  "Build a minimal entry plist."
  (list :id id :beat beat :wall-ns wall-ns
        :source source :path path
        :before before :after after :parent parent))

;; ---------------------------------------------------------------------------
;; edn serialisation round-trip
;; ---------------------------------------------------------------------------

(test edn-keyword-round-trip
  "edn-keyword serialises and parses correctly."
  (let ((kw (make-edn-keyword :name "txlog/user")))
    (is (string= ":txlog/user" (to-edn-string kw)))))

(test edn-integer-round-trip
  (is (string= "42" (to-edn-string 42))))

(test edn-string-round-trip
  (is (string= "\"hello\"" (to-edn-string "hello")))
  (is (string= "\"say \\\"hi\\\"\"" (to-edn-string "say \"hi\""))))

(test edn-bool-round-trip
  (is (string= "true" (to-edn-string t)))
  (is (string= "nil"  (to-edn-string nil))))

(test edn-list-round-trip
  (is (string= "[:a/b :c/d]"
               (to-edn-string (list (kw "a/b") (kw "c/d"))))))

;; ---------------------------------------------------------------------------
;; Lifecycle
;; ---------------------------------------------------------------------------

(test open-close
  "Can open and close an in-memory log without error."
  (let ((log (txlog:open ":memory:")))
    (is (log-p log))
    (txlog:close log)))

(test with-log-macro
  "with-log binds the log and closes it on exit."
  (with-log (log ":memory:")
    (is (log-p log))))

;; ---------------------------------------------------------------------------
;; register-source
;; ---------------------------------------------------------------------------

(test register-source-basic
  "register-source completes without error."
  (with-log (log ":memory:")
    (register-source log (kw "txlog/user") "User")
    (pass)))

(test register-source-idempotent
  "register-source is idempotent — calling twice does not error."
  (with-log (log ":memory:")
    (register-source log (kw "txlog/user") "User")
    (register-source log (kw "txlog/user") "User Different Name")
    (pass)))

;; ---------------------------------------------------------------------------
;; emit + read-all
;; ---------------------------------------------------------------------------

(test emit-and-read-all
  "Emitted entries are returned by read-all in write order."
  (with-log (log ":memory:")
    (let ((e1 (make-entry :beat 1.0d0 :after (kw "a/b")))
          (e2 (make-entry :beat 2.0d0 :after (kw "c/d"))))
      (emit log e1)
      (emit log e2)
      (let ((rows (read-all log)))
        (is (= 2 (length rows)))
        (is (= 1.0d0 (getf (first rows)  :beat)))
        (is (= 2.0d0 (getf (second rows) :beat)))))))

;; ---------------------------------------------------------------------------
;; history
;; ---------------------------------------------------------------------------

(test history-filters-by-path
  "history returns only entries matching the given path."
  (with-log (log ":memory:")
    (emit log (make-entry :path (make-path "a/x") :after "1" :beat 1.0d0))
    (emit log (make-entry :path (make-path "b/y") :after "2" :beat 2.0d0))
    (emit log (make-entry :path (make-path "a/x") :after "3" :beat 3.0d0))
    (let ((h (history log (make-path "a/x"))))
      (is (= 2 (length h)))
      (is (= 1.0d0 (getf (first h)  :beat)))
      (is (= 3.0d0 (getf (second h) :beat))))))

;; ---------------------------------------------------------------------------
;; at
;; ---------------------------------------------------------------------------

(test at-returns-latest-before-beat
  "at returns the after value of the latest write at or before the given beat."
  (with-log (log ":memory:")
    (emit log (make-entry :path (make-path "a/x") :after "v1" :beat 1.0d0))
    (emit log (make-entry :path (make-path "a/x") :after "v2" :beat 5.0d0))
    (is (equal "v1" (at log (make-path "a/x") 3.0d0)))
    (is (equal "v2" (at log (make-path "a/x") 5.0d0)))))

(test at-returns-nil-before-first-write
  (with-log (log ":memory:")
    (emit log (make-entry :path (make-path "a/x") :after "v" :beat 5.0d0))
    (is (null (at log (make-path "a/x") 2.0d0)))))

;; ---------------------------------------------------------------------------
;; range
;; ---------------------------------------------------------------------------

(test range-beat-window
  "range returns only entries within [from, to]."
  (with-log (log ":memory:")
    (loop for b in '(1.0d0 3.0d0 5.0d0 7.0d0)
          do (emit log (make-entry :beat b :after "v")))
    (let ((r (range log 3.0d0 5.0d0)))
      (is (= 2 (length r)))
      (is (= 3.0d0 (getf (first r)  :beat)))
      (is (= 5.0d0 (getf (second r) :beat))))))

;; ---------------------------------------------------------------------------
;; by-source
;; ---------------------------------------------------------------------------

(test by-source-filters
  (with-log (log ":memory:")
    (emit log (make-entry :source (kw "txlog/user")   :beat 1.0d0))
    (emit log (make-entry :source (kw "stumpwm/focus") :beat 2.0d0))
    (emit log (make-entry :source (kw "txlog/user")   :beat 3.0d0))
    (let ((r (by-source log (kw "txlog/user"))))
      (is (= 2 (length r))))))

;; ---------------------------------------------------------------------------
;; active-paths
;; ---------------------------------------------------------------------------

(test active-paths-distinct
  (with-log (log ":memory:")
    (emit log (make-entry :path (make-path "a/x") :beat 1.0d0))
    (emit log (make-entry :path (make-path "b/y") :beat 2.0d0))
    (emit log (make-entry :path (make-path "a/x") :beat 3.0d0))
    (let ((paths (active-paths log)))
      (is (= 2 (length paths))))))

;; ---------------------------------------------------------------------------
;; latest-values
;; ---------------------------------------------------------------------------

(test latest-values-last-write-wins
  "latest-values reflects the last after value per path."
  (with-log (log ":memory:")
    (emit log (make-entry :path (make-path "a/x") :after "v1" :beat 1.0d0))
    (emit log (make-entry :path (make-path "a/x") :after "v2" :beat 2.0d0))
    (let ((lv (latest-values log)))
      (is (= 1 (length lv)))
      (is (equal "v2" (cdr (first lv)))))))

(test latest-values-excludes-deletions
  "latest-values excludes paths whose last write had no after value."
  (with-log (log ":memory:")
    (emit log (make-entry :path (make-path "a/x") :after "v" :beat 1.0d0))
    (emit log (make-entry :path (make-path "a/x") :after nil     :beat 2.0d0))
    (let ((lv (latest-values log)))
      (is (null lv)))))

;; ---------------------------------------------------------------------------
;; crystallize
;; ---------------------------------------------------------------------------

(test crystallize-normalises-beats
  "crystallize normalises beat offsets relative to beat-from."
  (with-log (log ":memory:")
    (emit log (make-entry :path (make-path "a/x") :after "v1" :beat 10.0d0))
    (emit log (make-entry :path (make-path "a/x") :after "v2" :beat 15.0d0))
    (let ((result (crystallize log 10.0d0 20.0d0)))
      (let ((timeline (gethash (make-path "a/x") result)))
        (is (not (null timeline)))
        (is (= 0.0d0  (getf (first  timeline) :beat)))
        (is (= 5.0d0  (getf (second timeline) :beat)))))))

(test crystallize-excludes-schema-paths
  "crystallize excludes :txlog/schema paths by default."
  (with-log (log ":memory:")
    (emit log (make-entry :path (list (kw "txlog/schema") (kw "a/x"))
                          :after "v" :beat 1.0d0))
    (emit log (make-entry :path (make-path "a/x") :after "v" :beat 1.0d0))
    (let ((result (crystallize log 0.0d0 10.0d0)))
      (is (= 1 (hash-table-count result))))))

;; ---------------------------------------------------------------------------
;; diff
;; ---------------------------------------------------------------------------

(test diff-added
  "diff detects paths in b absent from a."
  (with-log (a ":memory:")
    (with-log (b ":memory:")
      (emit b (make-entry :path (make-path "new/key") :after "v"))
      (let ((d (diff a b)))
        (is (= 1 (length (diff-result-added d))))))))

(test diff-removed
  "diff detects paths in a absent from b."
  (with-log (a ":memory:")
    (with-log (b ":memory:")
      (emit a (make-entry :path (make-path "old/key") :after "v"))
      (let ((d (diff a b)))
        (is (= 1 (length (diff-result-removed d))))))))

(test diff-changed
  "diff detects paths present in both with different last values."
  (with-log (a ":memory:")
    (with-log (b ":memory:")
      (emit a (make-entry :path (make-path "shared/key") :after "v1"))
      (emit b (make-entry :path (make-path "shared/key") :after "v2"))
      (let ((d (diff a b)))
        (is (= 1 (length (diff-result-changed d))))))))

(test diff-unchanged
  "diff detects paths with the same last value in both logs."
  (with-log (a ":memory:")
    (with-log (b ":memory:")
      (emit a (make-entry :path (make-path "shared/key") :after "same"))
      (emit b (make-entry :path (make-path "shared/key") :after "same"))
      (let ((d (diff a b)))
        (is (= 1 (length (diff-result-unchanged d))))))))

;; ---------------------------------------------------------------------------
;; merge-into
;; ---------------------------------------------------------------------------

(test merge-into-basic
  "merge-into copies all entries from src into dst."
  (with-log (src ":memory:")
    (with-log (dst ":memory:")
      (emit src (make-entry :beat 1.0d0 :after "v1"))
      (emit src (make-entry :beat 2.0d0 :after "v2"))
      (merge-into dst src)
      (is (= 2 (length (read-all dst)))))))

;; ---------------------------------------------------------------------------
;; Daemon end-to-end (smoke)
;; ---------------------------------------------------------------------------

(defun %tmp-name (ext)
  (format nil "/tmp/txlog-test-~a-~a.~a" (get-universal-time) (random 1000000) ext))

(test daemon-roundtrip
  "Daemon receives register-source and emit over the socket, persists to DB."
  (let ((db   (%tmp-name "db"))
        (sock (%tmp-name "sock")))
    (unwind-protect
         (progn
           (txlog.daemon:start db sock)
           (txlog.client:with-client (c sock)
             (txlog.client:register-source c (kw "test/x") "X" "")
             (is (string= ":ok" (txlog.client:read-response c)))
             (txlog.client:emit c
               :id      "00000000-0000-0000-0000-000000000001"
               :source  (kw "test/x")
               :path    (make-path "a/b")
               :beat    1.0d0
               :wall-ns 1714000000000000000
               :after   "hello")
             (is (string= ":ok" (txlog.client:read-response c))))
           (txlog.daemon:stop)
           (with-log (l db)
             (let ((entries (read-all l)))
               (is (= 1 (length entries)))
               (is (string= "hello" (getf (first entries) :after))))))
      (when (txlog.daemon:running-p) (txlog.daemon:stop))
      (when (probe-file sock) (delete-file sock))
      (when (probe-file db)   (delete-file db)))))

;; ---------------------------------------------------------------------------
;; Runner
;; ---------------------------------------------------------------------------

(defun run-tests ()
  (run! 'txlog-suite))
