;; SPDX-License-Identifier: MIT
(ns txlog.core-test
  (:require [clojure.test :refer [deftest is testing]]
            [txlog.core   :as txlog]
            [txlog.source :as source])
  (:import [java.util UUID]))

;; ---------------------------------------------------------------------------
;; Helpers
;; ---------------------------------------------------------------------------

(defn- make-uuid [tag]
  (UUID. tag tag))

(defn- make-path [& kws]
  (vec (map keyword kws)))

(defn- entry
  ([id beat src path after]
   (entry id beat src path nil after))
  ([id beat src path before after]
   {:id      (make-uuid id)
    :beat    (double beat)
    :wall-ns (* beat 1000000000)
    :source  src
    :path    path
    :before  before
    :after   after
    :parent  nil}))

;; ---------------------------------------------------------------------------
;; Schema and registration
;; ---------------------------------------------------------------------------

(deftest schema-created-on-open
  (txlog/with-log [db ":memory:"]
    (is (empty? (txlog/read-all db)))))

(deftest register-source-is-idempotent
  (txlog/with-log [db ":memory:"]
    (txlog/register-source db source/user "User" "Direct user action")
    (txlog/register-source db source/user "User" "Direct user action")
    (txlog/register-source db source/user "Different description")
    (is (empty? (txlog/active-paths db)))))

;; ---------------------------------------------------------------------------
;; emit / read-all
;; ---------------------------------------------------------------------------

(deftest emit-and-read-all-round-trip
  (txlog/with-log [db ":memory:"]
    (txlog/register-source db source/user "User")
    (let [path [:synth/cutoff]
          e    (entry 1 1.0 source/user path 0.5)]
      (txlog/emit db e)
      (let [rows (txlog/read-all db)]
        (is (= 1 (count rows)))
        (let [r (first rows)]
          (is (= (:id e)      (:id r)))
          (is (= 1.0          (:beat r)))
          (is (= source/user  (:source r)))
          (is (= path         (:path r)))
          (is (nil?           (:before r)))
          (is (= 0.5          (:after r))))))))

(deftest emit-preserves-nullable-fields
  (txlog/with-log [db ":memory:"]
    (txlog/register-source db source/user "User")
    (let [e (assoc (entry 2 2.0 source/user [:synth/resonance] 0.3 0.7)
                   :parent :txlog/schema)]
      (txlog/emit db e)
      (let [r (first (txlog/read-all db))]
        (is (= 0.3           (:before r)))
        (is (= 0.7           (:after r)))
        (is (= :txlog/schema (:parent r)))))))

(deftest emit-preserves-multi-segment-path
  (txlog/with-log [db ":memory:"]
    (txlog/register-source db source/user "User")
    (let [path [:device/hydra :patch/cutoff]
          e    (entry 3 3.0 source/user path 127)]
      (txlog/emit db e)
      (is (= path (:path (first (txlog/read-all db))))))))

;; ---------------------------------------------------------------------------
;; Layer 2 queries
;; ---------------------------------------------------------------------------

(deftest history-returns-path-entries-in-order
  (txlog/with-log [db ":memory:"]
    (txlog/register-source db source/user "User")
    (let [path  [:synth/cutoff]
          other [:synth/volume]]
      (txlog/emit db (entry 1 1.0 source/user path   0.1))
      (txlog/emit db (entry 2 2.0 source/user other  0.5))
      (txlog/emit db (entry 3 3.0 source/user path   0.1 0.9))
      (let [hist (txlog/history db path)]
        (is (= 2   (count hist)))
        (is (= 0.1 (:after (first hist))))
        (is (= 0.9 (:after (second hist))))))))

(deftest at-returns-value-at-beat
  (txlog/with-log [db ":memory:"]
    (txlog/register-source db source/user "User")
    (let [path [:synth/cutoff]]
      (txlog/emit db (entry 1 1.0 source/user path 0.2))
      (txlog/emit db (entry 2 3.0 source/user path 0.2 0.8))
      (is (nil?  (txlog/at db path 0.5)))
      (is (= 0.2 (txlog/at db path 1.0)))
      (is (= 0.2 (txlog/at db path 2.0)))
      (is (= 0.8 (txlog/at db path 3.0)))
      (is (= 0.8 (txlog/at db path 99.0))))))

(deftest range-filters-by-beat-window
  (txlog/with-log [db ":memory:"]
    (txlog/register-source db source/user "User")
    (let [path [:synth/cutoff]]
      (doseq [[id beat val] [[1 1.0 0.1] [2 2.0 0.2] [3 3.0 0.3] [4 4.0 0.4]]]
        (txlog/emit db (entry id beat source/user path val)))
      (let [window (txlog/range db 2.0 3.0)]
        (is (= 2   (count window)))
        (is (= 0.2 (:after (first window))))
        (is (= 0.3 (:after (second window))))))))

(deftest range-filters-by-source-and-path
  (txlog/with-log [db ":memory:"]
    (txlog/register-source db source/user   "User")
    (txlog/register-source db source/schema "Schema")
    (let [path-a [:synth/cutoff]
          path-b [:synth/volume]]
      (txlog/emit db (entry 1 1.0 source/user   path-a 0.1))
      (txlog/emit db (entry 2 2.0 source/schema path-a 0.2))
      (txlog/emit db (entry 3 3.0 source/user   path-b 0.3))

      (testing "filter by source"
        (is (= 2 (count (txlog/range db 0.0 10.0 :source source/user)))))

      (testing "filter by path"
        (is (= 2 (count (txlog/range db 0.0 10.0 :path path-a)))))

      (testing "filter by source and path"
        (let [r (txlog/range db 0.0 10.0 :source source/user :path path-a)]
          (is (= 1   (count r)))
          (is (= 0.1 (:after (first r)))))))))

(deftest by-source-returns-matching-entries
  (txlog/with-log [db ":memory:"]
    (txlog/register-source db source/user   "User")
    (txlog/register-source db source/schema "Schema")
    (let [path [:synth/cutoff]]
      (txlog/emit db (entry 1 1.0 source/user   path 0.1))
      (txlog/emit db (entry 2 2.0 source/schema path 0.2))
      (txlog/emit db (entry 3 3.0 source/user   path 0.3))
      (is (= 2 (count (txlog/by-source db source/user))))
      (is (= 1 (count (txlog/by-source db source/schema)))))))

(deftest active-paths-returns-distinct-paths
  (txlog/with-log [db ":memory:"]
    (txlog/register-source db source/user "User")
    (let [path-a [:synth/cutoff]
          path-b [:synth/volume]]
      (txlog/emit db (entry 1 1.0 source/user path-a 0.1))
      (txlog/emit db (entry 2 2.0 source/user path-a 0.2))
      (txlog/emit db (entry 3 3.0 source/user path-b 0.5))
      (let [paths (txlog/active-paths db)]
        (is (= 2 (count paths)))
        (is (contains? paths path-a))
        (is (contains? paths path-b))))))

(deftest latest-values-folds-to-final-state
  (txlog/with-log [db ":memory:"]
    (txlog/register-source db source/user "User")
    (let [path-a [:synth/cutoff]
          path-b [:synth/volume]]
      (txlog/emit db (entry 1 1.0 source/user path-a 0.1))
      (txlog/emit db (entry 2 2.0 source/user path-a 0.1 0.9))
      (txlog/emit db (entry 3 3.0 source/user path-b 0.5))
      (let [latest (txlog/latest-values db)]
        (is (= 2   (count latest)))
        (is (= 0.9 (get latest path-a)))
        (is (= 0.5 (get latest path-b)))))))

(deftest latest-values-excludes-deletions
  (txlog/with-log [db ":memory:"]
    (txlog/register-source db source/user "User")
    (let [path [:synth/cutoff]]
      (txlog/emit db (entry 1 1.0 source/user path 0.5))
      (txlog/emit db {:id      (make-uuid 2)
                      :beat    2.0
                      :wall-ns 0
                      :source  source/user
                      :path    path
                      :before  0.5
                      :after   nil
                      :parent  nil})
      (is (empty? (txlog/latest-values db))))))

;; ---------------------------------------------------------------------------
;; Layer 3 — crystallize
;; ---------------------------------------------------------------------------

(deftest crystallize-normalises-beats
  (txlog/with-log [db ":memory:"]
    (txlog/register-source db source/user "User")
    (let [path [:synth/cutoff]]
      (txlog/emit db (entry 1 2.0 source/user path 0.2))
      (txlog/emit db (entry 2 4.0 source/user path 0.4))
      (txlog/emit db (entry 3 6.0 source/user path 0.6))
      (let [tl (txlog/crystallize db 2.0 5.0)]
        (is (contains? tl path))
        (is (= 2 (count (get tl path))))
        (is (= 0.0 (:beat (first (get tl path)))))
        (is (= 2.0 (:beat (second (get tl path)))))))))

(deftest crystallize-excludes-schema-paths-by-default
  (txlog/with-log [db ":memory:"]
    (txlog/register-source db source/user   "User")
    (txlog/register-source db source/schema "Schema")
    (let [schema-path [:txlog/schema :some-key]
          data-path   [:synth/cutoff]]
      (txlog/emit db (entry 1 1.0 source/schema schema-path true))
      (txlog/emit db (entry 2 2.0 source/user   data-path   0.5))

      (testing "excluded by default"
        (let [tl (txlog/crystallize db 0.0 10.0)]
          (is (not (contains? tl schema-path)))
          (is (contains? tl data-path))))

      (testing "included when requested"
        (let [tl (txlog/crystallize db 0.0 10.0 :include-schema? true)]
          (is (contains? tl schema-path))
          (is (contains? tl data-path)))))))

;; ---------------------------------------------------------------------------
;; diff
;; ---------------------------------------------------------------------------

(deftest diff-identifies-all-categories
  (txlog/with-log [a ":memory:"]
    (txlog/with-log [b ":memory:"]
      (txlog/register-source a source/user "User")
      (txlog/register-source b source/user "User")
      (let [shared  [:shared/key]
            changed [:changed/key]
            removed [:removed/key]
            added   [:added/key]]
        (txlog/emit a (entry 1 1.0 source/user shared  1.0))
        (txlog/emit a (entry 2 1.0 source/user changed 10))
        (txlog/emit a (entry 3 1.0 source/user removed 0.5))
        (txlog/emit b (entry 1 1.0 source/user shared  1.0))
        (txlog/emit b (entry 2 1.0 source/user changed 20))
        (txlog/emit b (entry 4 1.0 source/user added   99))
        (let [result (txlog/diff a b)]
          (is (= 1 (count (:added result))))
          (is (contains? (:added result) added))
          (is (= 1 (count (:removed result))))
          (is (contains? (:removed result) removed))
          (is (= 1 (count (:changed result))))
          (is (= {:before 10 :after 20} (get (:changed result) changed)))
          (is (= 1 (count (:unchanged result))))
          (is (contains? (:unchanged result) shared)))))))

(deftest diff-on-identical-logs
  (txlog/with-log [a ":memory:"]
    (txlog/with-log [b ":memory:"]
      (txlog/register-source a source/user "User")
      (txlog/register-source b source/user "User")
      (let [path [:synth/cutoff]]
        (txlog/emit a (entry 1 1.0 source/user path 0.5))
        (txlog/emit b (entry 2 1.0 source/user path 0.5))
        (let [result (txlog/diff a b)]
          (is (empty? (:added result)))
          (is (empty? (:removed result)))
          (is (empty? (:changed result)))
          (is (= 1 (count (:unchanged result)))))))))

(deftest diff-on-empty-logs
  (txlog/with-log [a ":memory:"]
    (txlog/with-log [b ":memory:"]
      (let [result (txlog/diff a b)]
        (is (empty? (:added result)))
        (is (empty? (:removed result)))
        (is (empty? (:changed result)))
        (is (empty? (:unchanged result)))))))

;; ---------------------------------------------------------------------------
;; merge-into
;; ---------------------------------------------------------------------------

(deftest merge-into-combines-entries
  (txlog/with-log [a ":memory:"]
    (txlog/with-log [b ":memory:"]
      (txlog/with-log [merged ":memory:"]
        (txlog/register-source a source/user "User")
        (txlog/register-source b source/user "User")
        (txlog/emit a (entry 1 1.0 source/user [:path/a] 0.1))
        (txlog/emit b (entry 2 2.0 source/user [:path/b] 0.2))
        (txlog/merge-into merged a)
        (txlog/merge-into merged b)
        (let [latest (txlog/latest-values merged)]
          (is (= 2   (count latest)))
          (is (= 0.1 (get latest [:path/a])))
          (is (= 0.2 (get latest [:path/b]))))))))
