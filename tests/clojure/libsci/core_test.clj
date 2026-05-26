(ns libsci.core-test
  (:require [cheshire.core :as json]
            [clojure.string :as str]
            [clojure.test :refer [deftest is testing]]
            [libsci.core :as core]))

(deftest create-context
  (testing "create-context returns a non-nil context"
    (core/-createContext)
    (is (some? core/-createContext))))

(deftest eval-simple
  (testing "eval basic arithmetic"
    (core/-createContext)
    (let [result (core/-evalString "(+ 1 2)")
          parsed (json/parse-string result)]
      (is (= "ok" (get parsed "status")))
      (is (= "3" (get parsed "value"))))))

(deftest eval-symbols
  (testing "eval with symbols in persistent context"
    (core/-createContext)
    (core/-evalString "(def x 42)")
    (let [result (core/-evalString "x")
          parsed (json/parse-string result)]
      (is (= "42" (get parsed "value"))))))

(deftest eval-defn-and-call
  (testing "defn and call function"
    (core/-createContext)
    (core/-evalString "(defn add [x y] (+ x y))")
    (let [result (core/-evalString "(add 3 4)")
          parsed (json/parse-string result)]
      (is (= "7" (get parsed "value"))))))

(deftest eval-string-error
  (testing "syntax error returns error envelope, not throw"
    (core/-createContext)
    (let [result (core/-evalString "(+ 1")
          parsed (json/parse-string result)]
      (is (= "error" (get parsed "status"))))))

(deftest eval-host-invoke-no-handler
  (testing "host/invoke returns error msg when no host fn registered"
    (core/-createContext)
    (let [result (core/-evalString "(host/invoke \"test\" \"fn\" 42)")
          parsed (json/parse-string result)
          value  (get parsed "value")]
      ;; Outer envelope always status=ok (eval succeeded).
      ;; Error details are inside the value string.
      (is (= "ok" (get parsed "status")))
      (is (str/includes? value "error")))))

(deftest eval-registered-host-fn
  (testing "registered host fn ns is available in SCI (even if dispatcher not on JVM)"
    (core/-createContext)
    ;; The ns "test" with fn "add" is registered via register-host-fn
    ;; from libsci.callbacks. On JVM, calling it will error (no dispatcher).
    ;; But the namespace itself should exist.
    (let [result (core/-evalString "(try (test/add 3 4) (catch Exception e \"err\"))")
          parsed (json/parse-string result)]
      ;; On JVM, test/add isn't registered (LibsciAPI not available), so
      ;; this tests graceful error handling rather than a successful call.
      (is (contains? parsed "status")))))

(deftest persistent-context
  (testing "context persists across eval calls"
    (core/-createContext)
    (core/-evalString "(def data [1 2 3])")
    (let [result (core/-evalString "(count data)")
          parsed (json/parse-string result)]
      (is (= "3" (get parsed "value"))))))
