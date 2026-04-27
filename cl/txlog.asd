(defsystem "txlog"
  :description "txlog — Common Lisp library and daemon for the txlog session log format"
  :version "0.1.0"
  :author "cljseq contributors"
  :license "BSL-1.0"
  :depends-on ("cl-sqlite"
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
  :components ((:file "test/test-log")))
