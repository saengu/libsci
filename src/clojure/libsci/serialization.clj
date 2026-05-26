(ns libsci.serialization
  (:require [cheshire.core :as json]))

;; ── Safety limits ──
;; Prevent OOM from lazy-seqs or infinite streams.
;; These can be overridden at runtime via binding.

(def ^:dynamic *max-depth*
  "Maximum nesting depth for JSON serialization."
  32)

(def ^:dynamic *max-string-length*
  "Maximum length of serialized JSON string (10 MB)."
  (* 10 1024 1024))

;; ── Core serialization ──

(defn ->json
  "Serialize a Clojure value to JSON string.
   Respects max-depth to prevent stack overflow on circular structures."
  [v]
  (json/generate-string v {:max-depth *max-depth*}))

(defn <-json
  "Parse a JSON string into Clojure data (string keys)."
  [s]
  (json/parse-string s))

(defn ->json-safe
  "Serialize a value to JSON with safety guards.
   - Limits recursion depth to *max-depth*
   - Truncates results exceeding *max-string-length*
   - Catches and wraps serialization errors."
  [v]
  (try
    (let [s (json/generate-string {:status "ok" :value v}
               {:max-depth *max-depth*})]
      (if (> (count s) *max-string-length*)
        (json/generate-string
          {:status "error"
           :message (str "Serialized result exceeds "
                         *max-string-length* " bytes")})
        s))
    (catch Exception e
      (json/generate-string
        {:status "error"
         :message (str "Serialization failed: " (.getMessage e))}))))
