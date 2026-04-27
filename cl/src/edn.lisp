; SPDX-License-Identifier: MIT
(in-package #:txlog.edn)

;; ---------------------------------------------------------------------------
;; edn-keyword
;;
;; EDN keywords are represented as a struct with a string name (without the
;; leading colon). The CL keyword symbol approach (:|txlog/user|) is rejected
;; because dotted namespace names like :org.cljseq/loop don't map cleanly to
;; CL package-qualified symbols.
;;
;; Serialised form in SQLite: ":txlog/user"  (with colon)
;; CL form:                   (make-edn-keyword :name "txlog/user")
;; ---------------------------------------------------------------------------

(defstruct (edn-keyword (:constructor make-edn-keyword (&key name))
                        (:predicate edn-keyword-p))
  (name "" :type string :read-only t))

(defmethod print-object ((kw edn-keyword) stream)
  (format stream ":~a" (edn-keyword-name kw)))

;; ---------------------------------------------------------------------------
;; to-edn-string — serialise a CL value to an EDN string for SQLite storage.
;;
;; Types handled (the txlog-actually-uses subset):
;;   edn-keyword  → ":ns/name"
;;   list/vector  → "[el1 el2 ...]"   (EDN vector)
;;   integer      → "42"
;;   float        → "1.5"
;;   string       → "\"hello\""
;;   t            → "true"
;;   nil          → "nil"
;;   hash-table   → "{:k1 v1 ...}"    (EDN map)
;;
;; Note on false: EDN distinguishes nil from false. CL does not. Two options:
;;   (a) Use the symbol TXLOG.EDN:FALSE as a sentinel for EDN false.
;;   (b) Accept the limitation — nil always round-trips as nil, never false.
;; The txlog format rarely stores raw boolean false; decide when it comes up.
;; ---------------------------------------------------------------------------

(defgeneric to-edn-string (value)
  (:documentation "Serialise VALUE to a compact EDN string."))

(defmethod to-edn-string ((kw edn-keyword))
  (format nil ":~a" (edn-keyword-name kw)))

(defmethod to-edn-string ((n integer))
  (format nil "~d" n))

(defmethod to-edn-string ((f float))
  ;; EDN uses standard decimal notation; avoid Lisp's 1.0d0 exponent syntax.
  (let ((s (format nil "~f" (coerce f 'double-float))))
    ;; Ensure at least one decimal digit is present.
    (if (find #\. s) s (concatenate 'string s ".0"))))

(defmethod to-edn-string ((s string))
  ;; Escape backslashes and double-quotes.
  (with-output-to-string (out)
    (write-char #\" out)
    (loop for c across s do
      (cond ((char= c #\\) (write-string "\\\\" out))
            ((char= c #\") (write-string "\\\"" out))
            (t             (write-char c out))))
    (write-char #\" out)))

(defmethod to-edn-string ((b (eql t)))
  "true")

(defmethod to-edn-string ((n null))
  "nil")

(defmethod to-edn-string ((seq list))
  (format nil "[~{~a~^ ~}]" (mapcar #'to-edn-string seq)))

(defmethod to-edn-string ((vec vector))
  (format nil "[~{~a~^ ~}]"
          (map 'list #'to-edn-string vec)))

(defmethod to-edn-string ((ht hash-table))
  (let ((pairs '()))
    (maphash (lambda (k v)
               (push (format nil "~a ~a" (to-edn-string k) (to-edn-string v))
                     pairs))
             ht)
    (format nil "{~{~a~^ ~}}" (nreverse pairs))))

;; ---------------------------------------------------------------------------
;; from-edn-string — deserialise an EDN string from SQLite.
;;
;; Stub. The full implementation needs a proper recursive-descent parser for
;; the txlog EDN subset. See clj/src/txlog/core.clj for what the Clojure side
;; produces — paths are always vectors of keywords, values are scalars or maps.
;;
;; The #uuid tagged literal is not stored as EDN in tx_id (raw BLOB); it may
;; appear in before/after/parent if callers put UUIDs there.
;; ---------------------------------------------------------------------------

(defun from-edn-string (s)
  "Parse EDN string S into a CL value. STUB — implement the full parser."
  (declare (ignore s))
  (error "from-edn-string: not yet implemented"))
