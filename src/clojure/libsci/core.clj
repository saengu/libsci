(ns libsci.core
  (:require [cheshire.core :as json]
            [sci.core :as sci]
            [libsci.callbacks])
  (:gen-class
   :methods [^{:static true} [evalString     [String] String]
             ^{:static true} [createContext   [] Object]
             ^{:static true} [callScriptFn   [String String String] String]]))

;; ── Isolate-local state ──
;; In GraalVM --shared mode, each Isolate has its own static state.
;; The reflection bridge to LibsciAPI is only available in native-image.
;; On JVM, we use a plain atom for state.

(defonce ^:private state (atom {:sci-ctx nil}))

(defn- has-libsci-api? []
  (try (Class/forName "libsci.LibsciAPI") true
       (catch ClassNotFoundException _ false)))

(defn get-sci-ctx
  "Get the current Isolate-local SCI context.
   In native-image mode, delegates to LibsciAPI.getSciCtx().
   On JVM, reads from an in-memory atom."
  []
  (if (has-libsci-api?)
    (let [cls  (Class/forName "libsci.LibsciAPI")
          meth (.getMethod cls "getSciCtx" (into-array Class []))]
      (.invoke meth nil (into-array Object [])))
    (:sci-ctx @state)))

(defn set-sci-ctx!
  "Set the current Isolate-local SCI context.
   In native-image mode, delegates to LibsciAPI.setSciCtx().
   On JVM, stores in an in-memory atom."
  [ctx]
  (if (has-libsci-api?)
    (let [cls  (Class/forName "libsci.LibsciAPI")
          meth (.getMethod cls "setSciCtx" (into-array Class [Object]))]
      (.invoke meth nil (into-array Object [ctx])))
    (swap! state assoc :sci-ctx ctx)))

;; ── Base SCI options ──

(defn- build-base-opts []
  {:namespaces {'cheshire.core
                {'generate-string json/generate-string
                 'parse-string    json/parse-string}
                'host
                {'invoke
                 (fn [& args]
                   (if (>= (count args) 2)
                     (let [[ns-name fn-name & rest-args] args
                           arg-json  (json/generate-string (vec rest-args))]
                       (if (try (Class/forName "libsci.LibsciAPI") true
                                (catch Throwable _ false))
                         (try
                           (let [cls   (Class/forName "libsci.LibsciAPI")
                                 meth  (.getMethod cls "invokeHostFn"
                                         (into-array Class [String String String]))
                                 raw   (.invoke meth nil
                                         (into-array Object
                                           [(str ns-name) (str fn-name) arg-json]))]
                             (if raw
                               (try
                                 (let [parsed (json/parse-string raw)]
                                   (if (= "ok" (get parsed "status"))
                                     (get parsed "value")
                                     {:status "error" :message (get parsed "message")}))
                                 (catch Exception e
                                   {:status "error"
                                    :message (str "Failed to parse: " (.getMessage e))}))
                               {:status "error" :message "Nil result from host fn"}))
                           (catch Throwable t
                             {:status "error"
                              :message (str "Host bridge error: " (.getMessage t))}))
                         {:status "error"
                          :message "Host bridge not available"}))
                     (str "host/invoke: expected at least 2 args, got " (count args))))}}})

;; ── Public API ──

(defn -createContext
  "Create a new SCI context. Called from Java sci_create_context."
  []
  (let [ctx (sci/init (build-base-opts))]
    (set-sci-ctx! ctx)
    ctx))

(defn -evalString
  "Evaluate a Clojure expression. Called from Java sci_eval_string."
  [s]
  (let [ctx (get-sci-ctx)]
    (if ctx
      (sci/binding [sci/out *out*]
        (try
          (let [result (sci/eval-string* ctx s)]
            (json/generate-string {:status "ok" :value (str result)}))
          (catch Exception e
            (json/generate-string
              {:status "error" :error (str (type e)) :message (.getMessage e)}))))
      (json/generate-string
        {:status "error" :message "No SCI context. Call create-context first."}))))

(defn -callScriptFn
  "Call a function in the SCI script context. Called from Java sci_call_script_fn.
   ns: namespace name, fn-name: function name, json-args: JSON array string."
  [ns-name fn-name json-args]
  (let [ctx (get-sci-ctx)]
    (if ctx
      (sci/binding [sci/out *out*]
        (try
          (let [expr   (str "(" ns-name "/" fn-name " " json-args ")")
                result (sci/eval-string* ctx expr)]
            (json/generate-string {:status "ok" :value (str result)}))
          (catch Exception e
            (json/generate-string
              {:status "error" :error (str (type e)) :message (.getMessage e)}))))
      (json/generate-string
        {:status "error" :message "No SCI context. Call create-context first."}))))
