(defproject org.babashka/sci-libsci "0.1.0"
  :description "libsci — babashka/SCI as an embeddable shared library"
  :url "https://github.com/saengu/libsci"
  :license {:name "Eclipse Public License 1.0"
            :url "http://opensource.org/licenses/eclipse-1.0.php"}
  ;; SCI sources from submodule + our Clojure bridge layer.
  :source-paths ["sci/src" "src/clojure"]
  :test-paths ["tests/clojure"]
  :dependencies [[org.clojure/clojure "1.10.3"]
                 [borkdude/edamame "1.5.39"]
                 [org.babashka/sci.impl.types "0.0.3"]
                 [borkdude/graal.locking "0.0.2"]
                 [cheshire "5.10.0"]]
  :profiles {:libsci {:source-paths ["sci/src" "src/clojure"]
                      :aot [libsci.core
                            libsci.callbacks
                            libsci.serialization]}
             :test {:dependencies [[criterium "0.4.5"]]}}
  :jvm-opts ["-Dclojure.spec.skip-macros=true"])
