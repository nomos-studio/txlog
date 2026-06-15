;; SPDX-License-Identifier: MIT
(ns txlog.source
  "Named constants for format-owned source vocabulary.
   EDN keyword namespace convention:
     :txlog/*        format-owned; every txlog-aware tool should understand
     :org.nous/*     nous-specific; opaque-but-valid to non-nous tools
     :<org>/*        open extension; any participant uses their own ns")

(def user   :txlog/user)
(def schema :txlog/schema)
(def error  :txlog/error)
(def undo   :txlog/undo)
