(ns libsci.callbacks
  (:require [cheshire.core :as json]
            [sci.core :as sci]))

;; ── Reflection bridge to LibsciAPI ──
;; Only available in native-image. On JVM, fall back to in-memory state.

(defonce ^:private host-fns (atom {}))

(defn- has-libsci-api? []
  (try
    (Class/forName "libsci.LibsciAPI")
    true
    (catch Throwable _
      false)))

(defn- invoke-host-ptr [ns-name fn-name args-json]
  (if (has-libsci-api?)
    (try
      (let [cls  (Class/forName "libsci.LibsciAPI")
            meth (.getMethod cls "invokeHostFn"
                   (into-array Class [String String String]))]
        (.invoke meth nil (into-array Object [ns-name fn-name args-json])))
      (catch Throwable t
        (json/generate-string
          {:status "error"
           :message (str "Host bridge error: " (.getMessage t))})))
    ;; On JVM, return error - no native dispatcher available
    (json/generate-string
      {:status "error"
       :message "Host bridge not available on JVM. Build with native-image first."})))

;; ── Register host function ──

(defn register-host-fn [ns-name fn-name]
  (let [wrapper (fn [& args]
                  (let [arg-json   (json/generate-string (vec args))
                        raw-result (invoke-host-ptr ns-name fn-name arg-json)]
                    (try
                      (let [parsed (json/parse-string raw-result)]
                        (if (= "ok" (get parsed "status"))
                          (get parsed "value")
                          (throw (ex-info (or (get parsed "message")
                                              "Host function error") parsed))))
                      (catch Exception e
                        (throw (ex-info (str "Host fn error: " (.getMessage e)) {}))))))]
    (let [ctx   ((resolve 'libsci.core/get-sci-ctx))
          opts  {:namespaces {(symbol ns-name) {(symbol fn-name) wrapper}}}]
      (when ctx
        (swap! host-fns assoc (str ns-name "/" fn-name) wrapper)
        (let [new-ctx (sci/merge-opts ctx opts)]
          ((resolve 'libsci.core/set-sci-ctx!) new-ctx))))))

;; ── Dynamic dispatch primitive ──
;; Called from the (host/invoke ns fn args...) binding in core.clj.

(defn dispatch-host-fn [ns-name fn-name args]
  (let [arg-json   (json/generate-string (vec args))
        raw-result (invoke-host-ptr ns-name fn-name arg-json)]
    (try
      (let [parsed (json/parse-string raw-result)]
        (if (= "ok" (get parsed "status"))
          (get parsed "value")
          {:status "error" :message (get parsed "message")}))
      (catch Exception e
        {:status "error"
         :message (str "Failed to parse host response: " (.getMessage e))}))))
