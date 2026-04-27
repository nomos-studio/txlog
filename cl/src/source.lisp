; SPDX-License-Identifier: MIT
(in-package #:txlog.source)

(defparameter +user+   (txlog.edn:make-edn-keyword :name "txlog/user"))
(defparameter +schema+ (txlog.edn:make-edn-keyword :name "txlog/schema"))
(defparameter +error+  (txlog.edn:make-edn-keyword :name "txlog/error"))
(defparameter +undo+   (txlog.edn:make-edn-keyword :name "txlog/undo"))
