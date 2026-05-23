(ns libsci-host-test
  (:require [cheshire.core :as json]
            [clojure.string :as str]
            [clojure.test :refer [deftest is testing]]
            [sci.impl.libsci-host :as host]))

(deftest load-and-call
  (testing "load a script and call a function defined in it"
    (host/-resetContext)
    (host/-loadScript "(defn add [x y] (+ x y))")
    (let [result (host/-callFunction "add" "3 4")]
      (is (= "7" (-> result json/parse-string (get "value")))))))

(deftest eval-in-context
  (testing "eval an expression in the persistent context"
    (host/-resetContext)
    (host/-loadScript "(def x 42)")
    (let [result (host/-evalInContext "x")]
      (is (= "42" (-> result json/parse-string (get "value")))))))

(deftest host-call-error-no-dispatcher
  (testing "host-call returns error when no dispatcher registered"
    (host/-resetContext)
    (let [result  (host/-loadScript "(host-call \"add\" 3 4)")
          parsed  (json/parse-string result)
          value   (get parsed "value")]
      (is (= "ok" (get parsed "status")))
      (is (str/includes? value "error") (str "expected error in value, got: " value)))))

(deftest context-reset-isolation
  (testing "reset + reload gives independent state (thread isolation simulated)"
    (host/-resetContext)
    (host/-loadScript "(def x 1)")
    (let [main-x (-> (host/-evalInContext "x") json/parse-string (get "value"))]
      (is (= "1" main-x))
      (host/-resetContext)
      (host/-loadScript "(def x 2)")
      (let [other-x (-> (host/-evalInContext "x") json/parse-string (get "value"))]
        (is (= "2" other-x))))))

(deftest load-script-error
  (testing "parse error returns JSON error, not throw"
    (host/-resetContext)
    (let [result (host/-loadScript "(+ 1")
          parsed (json/parse-string result)]
      (is (= "error" (get parsed "status")))
      (is (string? (get parsed "error"))))))

(deftest call-function-with-keyword
  (testing "call_function supports EDN keywords"
    (host/-resetContext)
    (host/-loadScript "(defn get-val [m k] (get m k))")
    (let [result (host/-callFunction "get-val" "{:a 1 :b 2} :a")]
      (is (= "1" (-> result json/parse-string (get "value")))))))

(deftest cross-ns-call
  (testing "call_function supports namespace-qualified fns"
    (host/-resetContext)
    (host/-loadScript "(ns my.ns) (defn calc [x] (* x 2))")
    (let [result (host/-callFunction "my.ns/calc" "21")]
      (is (= "42" (-> result json/parse-string (get "value")))))))
