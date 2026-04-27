; SPDX-License-Identifier: MIT
(in-package #:cl-user)

;; ---------------------------------------------------------------------------
;; txlog.edn — internal; EDN reader/writer for the txlog subset
;; ---------------------------------------------------------------------------
(defpackage #:txlog.edn
  (:use #:cl)
  (:export
   ;; Keyword type
   #:edn-keyword
   #:make-edn-keyword
   #:edn-keyword-p
   #:edn-keyword-name      ; string, e.g. "txlog/user" (no leading colon)
   ;; Serialise any CL value to an EDN string suitable for storage
   #:to-edn-string
   ;; Deserialise an EDN string read from SQLite back to a CL value
   #:from-edn-string))

;; ---------------------------------------------------------------------------
;; txlog.source — named constants for format-owned vocabulary
;; ---------------------------------------------------------------------------
(defpackage #:txlog.source
  (:use #:cl #:txlog.edn)
  (:export
   #:+user+
   #:+schema+
   #:+error+
   #:+undo+))

;; ---------------------------------------------------------------------------
;; txlog — main library (open, emit, query)
;; ---------------------------------------------------------------------------
(defpackage #:txlog
  (:use #:cl #:txlog.edn)
  (:shadow #:close)
  (:export
   ;; Lifecycle
   #:log
   #:open
   #:close
   #:with-log
   ;; Writer
   #:register-source
   #:emit
   ;; Layer 1
   #:read-all
   ;; Layer 2
   #:history
   #:at
   #:range
   #:by-source
   #:active-paths
   #:latest-values
   ;; Layer 3
   #:crystallize
   ;; Merge + diff
   #:merge-into
   #:diff
   #:diff-result
   #:diff-result-added
   #:diff-result-removed
   #:diff-result-changed
   #:diff-result-unchanged))

;; ---------------------------------------------------------------------------
;; txlog.client — thin write-only client; no SQLite dependency.
;;   Load this in StumpWM or any tool that only needs to emit events.
;; ---------------------------------------------------------------------------
(defpackage #:txlog.client
  (:use #:cl #:txlog.edn)
  (:export
   #:connect
   #:disconnect
   #:with-client
   #:register-source
   #:emit
   ;; Utility
   #:session-beat
   #:wall-ns))

;; ---------------------------------------------------------------------------
;; txlog.daemon — daemon server; owns the SQLite connection
;; ---------------------------------------------------------------------------
(defpackage #:txlog.daemon
  (:use #:cl #:txlog #:txlog.edn)
  (:export
   #:start
   #:stop
   #:running-p))
