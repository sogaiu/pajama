###
### C and C++ compiler rule utilties
###

(import ./config :as cnf)
(import ./rules :as r)
(import ./shutil :as sh)

(def- entry-replacer
  "Convert url with potential bad characters into an entry-name."
  (peg/compile
    ~(accumulate (any (choice (capture (range "AZ" "az" "09" "__"))
                              (replace (capture 1)
                                       ,|(string "_" (get $ 0) "_")))))))

(comment

  (peg/match entry-replacer "https://localhost")
  # =>
  @["https_58__47__47_localhost"]

  (peg/match entry-replacer "https://github.com/janet-lang/janet")
  # =>
  @["https_58__47__47_github_46_com_47_janet_45_lang_47_janet"]

  )

(defn entry-replace
  "Escape special characters in the entry-name."
  [name]
  (get (peg/match entry-replacer name) 0))

(defn embed-name
  "Rename a janet symbol for embedding."
  [path]
  (->> path
       (string/replace-all "\\" "___")
       (string/replace-all "/" "___")
       (string/replace-all ".janet" "")))

(comment

  (embed-name "/usr/local/src")
  # =>
  "___usr___local___src"

  (embed-name `C:\WINDOWS\SYSTEM32`)
  # =>
  "C:___WINDOWS___SYSTEM32"

  (embed-name "janet/src/boot/boot.janet")
  # =>
  "janet___src___boot___boot"

  )

(defn out-path
  "Take a source file path and convert it to an output path."
  [path from-ext to-ext]
  (->> path
       (string/replace-all "\\" "___")
       (string/replace-all "/" "___")
       (string/replace-all from-ext to-ext)
       (string (sh/find-build-dir))))

(defn make-define
  "Generate strings for adding custom defines to the compiler."
  [define value]
  (if value
    (string "-D" define "=" value)
    (string "-D" define)))

(comment

  (make-define "COOL_KNOB" "OFF")
  # =>
  "-DCOOL_KNOB=OFF"

  (make-define "SHIELDS_UP" nil)
  # =>
  "-DSHIELDS_UP"

  )

(defn make-defines
  "Generate many defines. Takes a dictionary of defines. If a value is
  true, generates -DNAME (/DNAME on windows), otherwise -DNAME=value."
  [defines]
  (def ret (seq [[d v] :pairs defines] (make-define d (when (not= v true) v))))
  (array/push ret (make-define "JANET_BUILD_TYPE" (cnf/dyn:build-type "release")))
  ret)

(defn- getflags
  "Generate the c flags from the input options."
  [opts compiler]
  (def flags (if (= compiler :cc) :cflags :cppflags))
  (def bt (cnf/dyn:build-type "release"))
  (def bto
    (cnf/opt opts
             :optimize
             (case bt
               "release" 2
               "debug" 0
               "develop" 2
               2)))
  (def oflag
    (if (dyn :is-msvc)
      (case bto 0 "/Od" 1 "/O1" 2 "/O2" "/O2")
      (case bto 0 "-O0" 1 "-O1" 2 "-O2" "-O3")))
  (def debug-syms
    (if (or (= bt "develop") (= bt "debug"))
      (if (dyn :is-msvc) ["/DEBUG"] ["-g"])
      []))
  @[;(cnf/opt opts flags)
    ;(if (cnf/dyn:verbose) (cnf/dyn:cflags-verbose) [])
    ;debug-syms
    (string "-I" (cnf/dyn:headerpath))
    (string "-I" (cnf/dyn:modpath))
    oflag])

(defn entry-name
  "Name of symbol that enters static compilation of a module."
  [name]
  (string "janet_module_entry_" (entry-replace name)))

(defn compile-c
  "Compile a C file into an object file."
  [compiler opts src dest &opt static?]
  (def cc (cnf/opt opts compiler))
  (def cflags [;(getflags opts compiler)
               ;(if static? [] (dyn :dynamic-cflags))])
  (def entry-defines (if-let [n (and static? (opts :entry-name))]
                       [(make-define "JANET_ENTRY_NAME" n)]
                       []))
  (def defines [;(make-defines (cnf/opt opts :defines {})) ;entry-defines])
  (def headers (or (opts :headers) []))
  (r/rule dest [src ;headers]
          (unless (cnf/dyn:verbose) (print "compiling " src " to " dest "...") (flush))
          (sh/create-dirs dest)
          (if (dyn :is-msvc)
            (sh/clexe-shell cc ;defines "/c" ;cflags (string "/Fo" dest) src)
            (sh/shell cc "-c" src ;defines ;cflags "-o" dest))))

(defn link-c
  "Link C or C++ object files together to make a native module."
  [has-cpp opts target & objects]
  (def linker (dyn (if has-cpp :c++-link :cc-link)))
  (def cflags (getflags opts (if has-cpp :c++ :cc)))
  (def lflags [;(cnf/opt opts :lflags)
               ;(if (opts :static) [] (cnf/dyn:dynamic-lflags))])
  (def deplibs (get opts :native-deps []))
  (def linkext
    (if (sh/is-win-or-mingw)
      (dyn :importlibext)
      (dyn :modext)))
  (def dep-ldflags (seq [x :in deplibs] (string (cnf/dyn:modpath) "/" x linkext)))
  # Use import libs on windows - we need an import lib to link natives to other natives.
  (def dep-importlibs
    (if (sh/is-win-or-mingw)
      (seq [x :in deplibs] (string (cnf/dyn:modpath) "/" x (dyn :importlibext)))
      @[]))
  (when-let [import-lib (dyn :janet-importlib)]
    (array/push dep-importlibs import-lib))
  (def dep-importlibs (distinct dep-importlibs))
  (def ldflags [;(cnf/opt opts :ldflags []) ;dep-ldflags])
  (r/rule target objects
          (unless (cnf/dyn:verbose) (print "creating native module " target "...") (flush))
          (sh/create-dirs target)
          (if (dyn :is-msvc)
            (sh/clexe-shell linker (string "/OUT:" target) ;objects ;dep-importlibs ;ldflags ;lflags)
            (sh/shell linker ;cflags `-o` target ;objects ;dep-importlibs ;ldflags ;lflags))))

(defn archive-c
  "Link object files together to make a static library."
  [opts target & objects]
  (def ar (cnf/opt opts :ar))
  (r/rule target objects
          (unless (cnf/dyn:verbose) (print "creating static library " target "...") (flush))
          (sh/create-dirs target)
          (if (dyn :is-msvc)
            (sh/shell ar "/nologo" (string "/out:" target) ;objects)
            (sh/shell ar "rcs" target ;objects))))

#
# Standalone C compilation
#

(defn create-buffer-c-impl
  [bytes dest name]
  (sh/create-dirs dest)
  (def out (file/open dest :wn))
  (def chunks (seq [b :in bytes] (string b)))
  (file/write out
              "#include <janet.h>\n"
              "static const unsigned char bytes[] = {"
              (string/join (interpose ", " chunks))
              "};\n\n"
              "const unsigned char *" name "_embed = bytes;\n"
              "size_t " name "_embed_size = sizeof(bytes);\n")
  (file/close out))

(defn create-buffer-c
  "Inline raw byte file as a c file."
  [source dest name]
  (r/rule dest [source]
          (print "generating " dest "...")
          (flush)
          (sh/create-dirs dest)
          (with [f (file/open source :rn)]
            (create-buffer-c-impl (:read f :all) dest name))))

(defn modpath-to-meta
  "Get the meta file path (.meta.janet) corresponding to a native module path (.so)."
  [path]
  (string (string/slice path 0 (- (length (cnf/dyn:modext)))) "meta.janet"))

(defn modpath-to-static
  "Get the static library (.a) path corresponding to a native module path (.so)."
  [path]
  (string (string/slice path 0 (- -1 (length (cnf/dyn:modext)))) (cnf/dyn:statext)))

(defn make-bin-source
  [declarations lookup-into-invocations no-core]
  (string
    declarations
    ```

int main(int argc, const char **argv) {

#if defined(JANET_PRF)
    uint8_t hash_key[JANET_HASH_KEY_SIZE + 1];
#ifdef JANET_REDUCED_OS
    char *envvar = NULL;
#else
    char *envvar = getenv("JANET_HASHSEED");
#endif
    if (NULL != envvar) {
        strncpy((char *) hash_key, envvar, sizeof(hash_key) - 1);
    } else if (janet_cryptorand(hash_key, JANET_HASH_KEY_SIZE) != 0) {
        fputs("unable to initialize janet PRF hash function.\n", stderr);
        return 1;
    }
    janet_init_hash_key(hash_key);
#endif

    janet_init();

    ```
    (if no-core
    ```
    /* Get core env */
    JanetTable *env = janet_table(8);
    JanetTable *lookup = janet_core_lookup_table(NULL);
    JanetTable *temptab;
    int handle = janet_gclock();
    ```
    ```
    /* Get core env */
    JanetTable *env = janet_core_env(NULL);
    JanetTable *lookup = janet_env_lookup(env);
    JanetTable *temptab;
    int handle = janet_gclock();
    ```)
    lookup-into-invocations
    ```
    /* Unmarshal bytecode */
    Janet marsh_out = janet_unmarshal(
      janet_payload_image_embed,
      janet_payload_image_embed_size,
      0,
      lookup,
      NULL);

    /* Verify the marshalled object is a function */
    if (!janet_checktype(marsh_out, JANET_FUNCTION)) {
        fprintf(stderr, "invalid bytecode image - expected function.");
        return 1;
    }
    JanetFunction *jfunc = janet_unwrap_function(marsh_out);

    /* Check arity */
    janet_arity(argc, jfunc->def->min_arity, jfunc->def->max_arity);

    /* Collect command line arguments */
    JanetArray *args = janet_array(argc);
    for (int i = 0; i < argc; i++) {
        janet_array_push(args, janet_cstringv(argv[i]));
    }

    /* Create enviornment */
    temptab = env;
    janet_table_put(temptab, janet_ckeywordv("args"), janet_wrap_array(args));
    janet_table_put(temptab, janet_ckeywordv("executable"), janet_cstringv(argv[0]));
    janet_gcroot(janet_wrap_table(temptab));

    /* Unlock GC */
    janet_gcunlock(handle);

    /* Run everything */
    JanetFiber *fiber = janet_fiber(jfunc, 64, argc, argc ? args->data : NULL);
    fiber->env = temptab;
#ifdef JANET_EV
    janet_gcroot(janet_wrap_fiber(fiber));
    janet_schedule(fiber, janet_wrap_nil());
    janet_loop();
    int status = janet_fiber_status(fiber);
    janet_deinit();
    return status;
#else
    Janet out;
    JanetSignal result = janet_continue(fiber, janet_wrap_nil(), &out);
    if (result != JANET_SIGNAL_OK && result != JANET_SIGNAL_EVENT) {
      janet_stacktrace(fiber, out);
      janet_deinit();
      return result;
    }
    janet_deinit();
    return 0;
#endif
}

```))

(defn create-executable
  "Links an image with libjanet.a (or .lib) to produce an
  executable. Also will try to link native modules into the
  final executable as well."
  [opts source dest no-core]

  # Create executable's janet image
  (def cimage_dest (string dest ".c"))
  (def no-compile (opts :no-compile))
  (def bd (sh/find-build-dir))
  (r/rule (if no-compile cimage_dest dest) [source]
          (print "generating executable c source " cimage_dest " from " source "...")
          (flush)
          (sh/create-dirs dest)

          # Monkey patch stuff
          (def token (sh/do-monkeypatch bd))
          (defer (sh/undo-monkeypatch token)

            # Load entry environment and get main function.
            (def env (make-env))
            (def entry-env (dofile source :env env))
            (def main (get-in entry-env ['main :value]))
            (assert (and main (function? main))
                    (string/format "no main function in %s" source))
            (def dep-lflags @[])
            (def dep-ldflags @[])

            # Create marshalling dictionary
            (def mdict1 (invert (env-lookup root-env)))
            (def mdict
              (if no-core
                (let [temp @{}]
                  (eachp [k v] mdict1
                    (when (or (cfunction? k) (abstract? k))
                      (put temp k v)))
                  temp)
                mdict1))

            # Load all native modules
            (def prefixes @{})
            (def static-libs @[])
            (loop [[name m] :pairs module/cache
                   :let [n (m :native)]
                   :when n
                   :let [prefix (gensym)]]
              (print "found native " n "...")
              (flush)
              (put prefixes prefix n)
              (array/push static-libs (modpath-to-static n))
              (def oldproto (table/getproto m))
              (table/setproto m nil)
              (loop [[sym value] :pairs (env-lookup m)]
                (put mdict value (symbol prefix sym)))
              (table/setproto m oldproto))

            # Find static modules
            (var has-cpp false)
            (def declarations @"")
            (def lookup-into-invocations @"")
            (loop [[prefix name] :pairs prefixes]
              (def meta (eval-string (slurp (modpath-to-meta name))))
              (when (meta :cpp) (set has-cpp true))
              (buffer/push-string lookup-into-invocations
                                  "    temptab = janet_table(0);\n"
                                  "    temptab->proto = env;\n"
                                  "    " (meta :static-entry) "(temptab);\n"
                                  "    janet_env_lookup_into(lookup, temptab, \""
                                  prefix
                                  "\", 0);\n\n")
              (when-let [lfs (meta :lflags)]
                (array/concat dep-lflags lfs))
              (when-let [lfs (meta :ldflags)]
                (array/concat dep-ldflags lfs))
              (buffer/push-string declarations
                                  "extern void "
                                  (meta :static-entry)
                                  "(JanetTable *);\n"))

            # Build image
            (def image (marshal main mdict))
            # Make image byte buffer
            (create-buffer-c-impl image cimage_dest "janet_payload_image")
            # Append main function
            (spit cimage_dest (make-bin-source declarations lookup-into-invocations no-core) :ab)
            (def oimage_dest (out-path cimage_dest ".c" ".o"))
            # Compile and link final exectable
            (unless no-compile
              (def ldflags [;dep-ldflags ;(cnf/opt opts :ldflags [])])
              (def lflags [;static-libs
                           (string (cnf/dyn:libpath) "/libjanet." (last (string/split "." (cnf/dyn:statext))))
                           ;dep-lflags ;(cnf/opt opts :lflags []) ;(cnf/dyn:janet-lflags)])
              (def defines (make-defines (cnf/opt opts :defines {})))
              (def cc (cnf/opt opts :cc))
              (def cflags [;(getflags opts :cc) ;(cnf/dyn:janet-cflags)])
              (print "compiling " cimage_dest " to " oimage_dest "...")
              (flush)
              (sh/create-dirs oimage_dest)
              (if (cnf/dyn:is-msvc)
                (sh/clexe-shell cc ;defines "/c" ;cflags (string "/Fo" oimage_dest) cimage_dest)
                (sh/shell cc "-c" cimage_dest ;defines ;cflags "-o" oimage_dest))
              (if has-cpp
                (let [linker (cnf/opt opts (if (dyn :is-msvc) :c++-link :c++))
                      cppflags [;(getflags opts :c++) ;(cnf/dyn:janet-cflags)]]
                  (print "linking " dest "...")
                  (flush)
                  (if (cnf/dyn:is-msvc)
                    (sh/clexe-shell linker (string "/OUT:" dest) oimage_dest ;ldflags ;lflags)
                    (sh/shell linker ;cppflags `-o` dest oimage_dest ;ldflags ;lflags)))
                (let [linker (cnf/opt opts (if (cnf/dyn:is-msvc) :cc-link :cc))]
                  (print "linking " dest "...")
                  (flush)
                  (sh/create-dirs dest)
                  (if (cnf/dyn:is-msvc)
                    (sh/clexe-shell linker (string "/OUT:" dest) oimage_dest ;ldflags ;lflags)
                    (sh/shell linker ;cflags `-o` dest oimage_dest ;ldflags ;lflags))))))))
