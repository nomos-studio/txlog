(defsystem "txlog"
  :description "txlog — Common Lisp library and daemon for the txlog session log format"
  :version "0.1.0"
  :author "nomos-studio contributors"
  :license "BSL-1.0"
  :depends-on ("sqlite"
               "bordeaux-threads"
               "usocket"
               "babel")
  :serial t
  :components ((:file "src/package")
               (:file "src/edn")
               (:file "src/source")
               (:file "src/log")
               (:file "src/client")
               (:file "src/daemon"))
  :in-order-to ((test-op (test-op "txlog/test"))))

(defsystem "txlog/test"
  :depends-on ("txlog" "fiveam")
  :serial t
  :components ((:file "test/test-log"))
  :perform (test-op (op c)
             (let* ((suite   (uiop:find-symbol* :txlog-suite :txlog/test))
                    (results (uiop:symbol-call :fiveam :run suite)))
               (uiop:symbol-call :fiveam :explain! results)
               (unless (uiop:symbol-call :fiveam :results-status results)
                 (uiop:quit 1)))))
