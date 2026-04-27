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

(defun handle-request (log request-string stream)
  "Parse REQUEST-STRING as an EDN map, dispatch, write response to STREAM.
   STUB — implement dispatch after from-edn-string is available."
  (declare (ignore log request-string))
  ;; Placeholder: echo :ok until the EDN reader is implemented.
  (write-string ":ok" stream)
  (write-char #\newline stream)
  (finish-output stream))

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
  "Loop accepting connections; each gets a handler thread."
  (loop
    (handler-case
        (let ((conn (usocket:socket-accept server-socket
                                           :element-type '(unsigned-byte 8))))
          (bt:make-thread
           (lambda () (handle-connection log conn))
           :name "txlog-connection"))
      (usocket:socket-error ()
        ;; Server socket closed — normal shutdown.
        (return))
      (error (e)
        (format *error-output* "txlog-daemon: accept error: ~a~%" e)))))

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
           (server (usocket:socket-listen socket-path 5
                                          :element-type '(unsigned-byte 8)))
           (thread (bt:make-thread
                    (lambda () (%accept-loop log server))
                    :name "txlog-listener")))
      (setf *log*             log
            *server-socket*   server
            *listener-thread* thread)
      t)))

(defun stop ()
  "Stop the daemon: close the server socket and the log.
   Blocks until the listener thread exits."
  (bt:with-lock-held (*state-lock*)
    (when *server-socket*
      (usocket:socket-close *server-socket*)
      (setf *server-socket* nil))
    (when *listener-thread*
      (bt:join-thread *listener-thread*)
      (setf *listener-thread* nil))
    (when *log*
      (txlog:close *log*)
      (setf *log* nil))))
