; SPDX-License-Identifier: MIT
(in-package #:txlog.edn)

;; ---------------------------------------------------------------------------
;; edn-keyword
;;
;; EDN keywords are represented as a struct with a string name (without the
;; leading colon). The CL keyword symbol approach (:|txlog/user|) is rejected
;; because dotted namespace names like :org.nous/loop don't map cleanly to
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
;; Recursive-descent parser for the txlog EDN subset. EDN false maps to nil
;; (CL has no separate false). The #uuid tagged literal is not handled here —
;; tx_id is stored as a raw BLOB, never as #uuid in EDN.
;; ---------------------------------------------------------------------------

(defparameter +edn-whitespace+ '(#\Space #\Tab #\Newline #\Return #\,))

(defparameter +edn-delimiters+
  '(#\Space #\Tab #\Newline #\Return #\, #\] #\} #\) #\[ #\{ #\())

(defun %edn-skip-ws (in)
  (loop for c = (peek-char nil in nil nil)
        while (and c (member c +edn-whitespace+))
        do (read-char in)))

(defun %edn-read-token (in)
  "Read a contiguous run of non-delimiter chars."
  (with-output-to-string (out)
    (loop for c = (peek-char nil in nil nil)
          while (and c (not (member c +edn-delimiters+)))
          do (write-char (read-char in) out))))

(defun %edn-parse (in)
  (%edn-skip-ws in)
  (let ((c (peek-char nil in nil nil)))
    (cond
      ((null c)              (error "from-edn-string: unexpected eof"))
      ((char= c #\:)         (%edn-parse-keyword in))
      ((char= c #\")         (%edn-parse-string in))
      ((char= c #\[)         (%edn-parse-vector in))
      ((char= c #\{)         (%edn-parse-map in))
      ((or (digit-char-p c)
           (char= c #\-)
           (char= c #\+))    (%edn-parse-number in))
      ((alpha-char-p c)      (%edn-parse-symbol in))
      (t (error "from-edn-string: unexpected char ~s" c)))))

(defun %edn-parse-keyword (in)
  (read-char in)              ; consume #\:
  (let ((name (%edn-read-token in)))
    (when (zerop (length name))
      (error "from-edn-string: empty keyword"))
    (make-edn-keyword :name name)))

(defun %edn-parse-string (in)
  (read-char in)              ; consume opening #\"
  (with-output-to-string (out)
    (loop for c = (read-char in nil nil) do
      (cond
        ((null c)        (error "from-edn-string: unterminated string"))
        ((char= c #\")   (return))
        ((char= c #\\)
         (let ((esc (read-char in nil nil)))
           (case esc
             (#\"       (write-char #\" out))
             (#\\       (write-char #\\ out))
             (#\n       (write-char #\Newline out))
             (#\t       (write-char #\Tab out))
             (#\r       (write-char #\Return out))
             (otherwise (error "from-edn-string: bad escape \\~a" esc)))))
        (t (write-char c out))))))

(defun %edn-parse-vector (in)
  (read-char in)              ; consume #\[
  (let ((items '()))
    (loop
      (%edn-skip-ws in)
      (let ((c (peek-char nil in nil nil)))
        (cond
          ((null c)        (error "from-edn-string: unterminated vector"))
          ((char= c #\])   (read-char in) (return (nreverse items)))
          (t               (push (%edn-parse in) items)))))))

(defun %edn-parse-map (in)
  (read-char in)              ; consume #\{
  ;; equalp so edn-keyword keys compare structurally by name.
  (let ((ht (make-hash-table :test 'equalp)))
    (loop
      (%edn-skip-ws in)
      (let ((c (peek-char nil in nil nil)))
        (cond
          ((null c)        (error "from-edn-string: unterminated map"))
          ((char= c #\})   (read-char in) (return ht))
          (t (let* ((k (%edn-parse in))
                    (v (progn (%edn-skip-ws in) (%edn-parse in))))
               (setf (gethash k ht) v))))))))

(defun %edn-parse-number (in)
  (let* ((token (%edn-read-token in))
         (val   (let ((*read-default-float-format* 'double-float))
                  (read-from-string token))))
    (unless (numberp val)
      (error "from-edn-string: bad number ~s" token))
    val))

(defun %edn-parse-symbol (in)
  (let ((token (%edn-read-token in)))
    (cond
      ((string= token "nil")   nil)
      ((string= token "true")  t)
      ((string= token "false") nil)   ; CL has no false; EDN false → nil
      (t (error "from-edn-string: unknown symbol ~s" token)))))

(defun from-edn-string (s)
  "Parse EDN string S into a CL value. The txlog subset only — keywords,
   strings, integers, doubles, booleans, nil, vectors of those, and maps."
  (with-input-from-string (in s)
    (%edn-parse in)))
