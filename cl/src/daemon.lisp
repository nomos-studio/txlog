; SPDX-License-Identifier: MIT
(in-package #:txlog.daemon)

;; ---------------------------------------------------------------------------
;; txlog.daemon — single-writer daemon that owns the SQLite connection.
;;
;; Architecture:
;;   - One listener thread accepts Unix domain socket connections.
;;   - Each accepted connection gets a handler thread.
;;   - All writes to SQLite are serialised via the lock inside the txlog struct
;;     (txlog:emit already acquires it).
;;   - The daemon is session-scoped; start from org-babel or shell.
;;
;; Wire protocol: one EDN map per message, followed by a newline.
;;   Request: {:op :emit | :register-source | :query ...}
;;   Response: :ok  or  {:error "message"}
;;
;; Socket path: $XDG_RUNTIME_DIR/txlog/<session>.sock
;; ---------------------------------------------------------------------------

;; ---------------------------------------------------------------------------
;; Global state
;; ---------------------------------------------------------------------------

(defvar *log*            nil "The open txlog:log being served.")
(defvar *server-socket*  nil "The listening usocket server socket.")
(defvar *listener-thread* nil "The bt thread running the accept loop.")
(defvar *state-lock*     (bt:make-lock "txlog-daemon-state") "Guards above vars.")

;; ---------------------------------------------------------------------------
;; Predicates
;; ---------------------------------------------------------------------------

(defun running-p ()
  "True if the daemon is running (socket open and listener alive)."
  (bt:with-lock-held (*state-lock*)
    (and *server-socket*
         *listener-thread*
         (bt:thread-alive-p *listener-thread*))))

;; ---------------------------------------------------------------------------
;; Request handler — parses one EDN request map, dispatches, writes response
;; ---------------------------------------------------------------------------
;;
;; Wire protocol (one EDN map per line):
;;   {:op :emit            :id "uuid" :source :ns/k :path [..] :beat .. :wall-ns ..
;;                         :before .. :after .. :parent ..}
;;   {:op :register-source :id :ns/k :name "..." :description "..."}
;;
;; Responses:
;;   :ok                 — success
;;   {:error "message"}  — failure
;;
;; :query is not handled here. Reads go directly via SQLite WAL from any peer.

(defun %edn-kw= (val name)
  "True if VAL is an edn-keyword whose name string-= NAME."
  (and (txlog.edn:edn-keyword-p val)
       (string= (txlog.edn:edn-keyword-name val) name)))

(defun %get-field (request name)
  "Look up an edn-keyword-named field in REQUEST (a hash-table from from-edn-string)."
  (gethash (txlog.edn:make-edn-keyword :name name) request))

(defun %write-ok (stream)
  (write-string ":ok" stream)
  (write-char #\newline stream)
  (finish-output stream))

(defun %write-error (stream message)
  (format stream "{:error ~a}~%" (txlog.edn:to-edn-string message))
  (finish-output stream))

(defun %do-emit (log request)
  (txlog:emit log
              (list :id      (%get-field request "id")
                    :beat    (%get-field request "beat")
                    :wall-ns (%get-field request "wall-ns")
                    :source  (%get-field request "source")
                    :path    (%get-field request "path")
                    :before  (%get-field request "before")
                    :after   (%get-field request "after")
                    :parent  (%get-field request "parent"))))

(defun %do-register-source (log request)
  (txlog:register-source log
                         (%get-field request "id")
                         (%get-field request "name")
                         (%get-field request "description")))

(defun handle-request (log request-string stream)
  "Parse REQUEST-STRING as an EDN map, dispatch by :op, write response to STREAM."
  (handler-case
      (let* ((request (txlog.edn:from-edn-string request-string))
             (op      (when (hash-table-p request) (%get-field request "op"))))
        (cond
          ((null op)
           (%write-error stream "missing :op"))
          ((%edn-kw= op "emit")
           (%do-emit log request)
           (%write-ok stream))
          ((%edn-kw= op "register-source")
           (%do-register-source log request)
           (%write-ok stream))
          (t
           (%write-error stream (format nil "unknown :op ~a" op)))))
    (error (e)
      (%write-error stream (format nil "~a" e)))))

;; ---------------------------------------------------------------------------
;; Connection handler — reads newline-terminated messages and dispatches
;; ---------------------------------------------------------------------------

(defun handle-connection (log conn-socket)
  "Service one client connection until it closes or errors."
  (let ((stream (usocket:socket-stream conn-socket)))
    (handler-case
        (loop
          (let ((line (read-line stream nil nil)))
            (unless line (return))
            (unless (string= (string-trim '(#\space #\tab #\return) line) "")
              (handle-request log line stream))))
      (error (e)
        (format *error-output* "txlog-daemon: connection error: ~a~%" e)))
    (usocket:socket-close conn-socket)))

;; ---------------------------------------------------------------------------
;; Listener loop
;; ---------------------------------------------------------------------------

(defun %accept-loop (log server-socket)
  "Loop accepting connections; each gets a handler thread.
   Exits on any accept error (closed socket) or on a 'shutdown throw raised
   from another thread via bt:interrupt-thread."
  (catch 'shutdown
    (loop
      (let ((conn (handler-case
                      (usocket:socket-accept server-socket
                                             :element-type 'character)
                    (error () (return)))))
        (bt:make-thread
         (lambda () (handle-connection log conn))
         :name "txlog-connection")))))

;; ---------------------------------------------------------------------------
;; Lifecycle
;; ---------------------------------------------------------------------------

(defun start (db-path socket-path)
  "Start the daemon: open DB-PATH, listen on SOCKET-PATH.
   Idempotent — if already running, does nothing and returns nil.
   Returns t on successful start."
  (bt:with-lock-held (*state-lock*)
    (when (and *listener-thread* (bt:thread-alive-p *listener-thread*))
      (return-from start nil))
    ;; Stale socket file from a previous crash — remove it.
    (when (probe-file socket-path)
      (delete-file socket-path))
    (let* ((log    (txlog:open db-path))
           ;; Pathname host + nil port → usocket selects Unix domain socket.
           ;; Character element-type so read-line works on accepted streams.
           (server (usocket:socket-listen (pathname socket-path) nil
                                          :backlog 5
                                          :element-type 'character))
           (thread (bt:make-thread
                    (lambda () (%accept-loop log server))
                    :name "txlog-listener")))
      (setf *log*             log
            *server-socket*   server
            *listener-thread* thread)
      t)))

(defun stop ()
  "Stop the daemon: signal the listener out of accept(), close sockets and DB.
   Blocks until the listener thread exits."
  (bt:with-lock-held (*state-lock*)
    (when (and *listener-thread* (bt:thread-alive-p *listener-thread*))
      ;; socket-close alone does not unblock a Unix-domain accept on Linux,
      ;; so we explicitly throw out of the accept call.
      (handler-case
          (bt:interrupt-thread *listener-thread*
                               (lambda () (throw 'shutdown nil)))
        (error () nil))
      (bt:join-thread *listener-thread*))
    (setf *listener-thread* nil)
    (when *server-socket*
      (handler-case (usocket:socket-close *server-socket*) (error () nil))
      (setf *server-socket* nil))
    (when *log*
      (txlog:close *log*)
      (setf *log* nil))))
