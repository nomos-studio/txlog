; SPDX-License-Identifier: MIT
(in-package #:txlog.client)

;; ---------------------------------------------------------------------------
;; txlog.client — thin write-only client; talks to a running txlog daemon
;; via a Unix domain socket.  No SQLite dependency.  Safe to load in StumpWM.
;;
;; The daemon owns the SQLite connection. This library is the sender side only.
;; ---------------------------------------------------------------------------

;; ---------------------------------------------------------------------------
;; Connection handle
;; ---------------------------------------------------------------------------

(defstruct (client (:constructor %make-client)
                   (:predicate client-p))
  socket       ; usocket stream-usocket
  stream       ; socket stream for writes
  socket-path) ; string — original path, for reconnect

;; ---------------------------------------------------------------------------
;; Lifecycle
;; ---------------------------------------------------------------------------

(defun connect (socket-path)
  "Open a connection to the txlog daemon at SOCKET-PATH.
   Returns a client handle.  Signals an error if the socket is not reachable."
  (let* ((sock   (usocket:socket-connect socket-path nil
                                         :element-type '(unsigned-byte 8)
                                         :protocol     :stream))
         (stream (usocket:socket-stream sock)))
    (%make-client :socket      sock
                  :stream      stream
                  :socket-path socket-path)))

(defun disconnect (client)
  "Close the connection to the daemon."
  (usocket:socket-close (client-socket client)))

(defmacro with-client ((var socket-path) &body body)
  "Connect to the daemon at SOCKET-PATH, bind it to VAR, and disconnect on exit."
  `(let ((,var (connect ,socket-path)))
     (unwind-protect
          (progn ,@body)
       (disconnect ,var))))

;; ---------------------------------------------------------------------------
;; Utilities
;; ---------------------------------------------------------------------------

(defun wall-ns ()
  "Current POSIX time in nanoseconds. STUB — replace with a platform call."
  (error "wall-ns: not yet implemented"))

(defun session-beat ()
  "Current session beat at 60bpm (1 beat = 1 second) from the session epoch.
   STUB — the caller must supply a session-start wall-ns and compute the delta."
  (error "session-beat: not yet implemented"))

;; ---------------------------------------------------------------------------
;; Wire helpers
;; ---------------------------------------------------------------------------

(defun %send-message (client map-string)
  "Write MAP-STRING (a serialised EDN map) to the daemon, followed by a newline.
   Flushes immediately.  No response is read."
  (let ((bytes (babel:string-to-octets (concatenate 'string map-string #.(string #\newline))
                                       :encoding :utf-8)))
    (write-sequence bytes (client-stream client))
    (finish-output (client-stream client))))

(defun %edn-map (&rest kv-pairs)
  "Build a minimal EDN map string from alternating key/value strings.
   Keys and values must already be EDN-serialised strings."
  (with-output-to-string (out)
    (write-char #\{ out)
    (loop for (k v) on kv-pairs by #'cddr
          for first = t then nil
          unless first do (write-char #\space out)
          do (format out "~a ~a" k v))
    (write-char #\} out)))

;; ---------------------------------------------------------------------------
;; Writer
;; ---------------------------------------------------------------------------

(defun register-source (client id name &optional description)
  "Register a source with the daemon. Idempotent.
   ID is an edn-keyword; NAME and DESCRIPTION are strings."
  (%send-message
   client
   (%edn-map ":op"          ":register-source"
             ":id"          (txlog.edn:to-edn-string id)
             ":name"        (txlog.edn:to-edn-string name)
             ":description" (if description
                                (txlog.edn:to-edn-string description)
                                "nil"))))

(defun emit (client &key id source path beat wall-ns before after parent)
  "Emit one entry to the daemon. All keyword arguments except :BEFORE, :AFTER,
   and :PARENT are required.
   SOURCE is an edn-keyword; PATH is a list of edn-keywords."
  (let ((pairs (list ":op"      ":emit"
                     ":source"  (txlog.edn:to-edn-string source)
                     ":path"    (txlog.edn:to-edn-string path)
                     ":beat"    (txlog.edn:to-edn-string (float beat 1.0d0))
                     ":wall-ns" (txlog.edn:to-edn-string wall-ns))))
    (when id
      (setf pairs (append pairs (list ":id" (txlog.edn:to-edn-string id)))))
    (when before
      (setf pairs (append pairs (list ":before" (txlog.edn:to-edn-string before)))))
    (when after
      (setf pairs (append pairs (list ":after"  (txlog.edn:to-edn-string after)))))
    (when parent
      (setf pairs (append pairs (list ":parent" (txlog.edn:to-edn-string parent)))))
    (%send-message client (apply #'%edn-map pairs))))
