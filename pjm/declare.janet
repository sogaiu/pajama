###
### Rule generation for adding native source code
###

(import ./config :as cnf)
(import ./rules :as r)
(import ./shutil :as sh)
(import ./cc)

(defn- check-release
  []
  (= "release" (cnf/dyn:build-type "release")))

(defn- dofile-codegen
  [in-path out-path]
  (with [f (file/open out-path :wbn)]
    (def env (make-env))
    (put env :out f)
    (dofile in-path :env env)))

(defn install-rule
  "Add install and uninstall rule for moving files from src into destdir."
  [src destdir]
  (unless (check-release) (break))
  (def name (last (peg/match sh/path-splitter src)))
  (def path (string destdir "/" name))
  (array/push (dyn :installed-files) path)
  (def dir (string (dyn :dest-dir "") destdir))
  (r/task "install" []
          (os/mkdir dir)
          (sh/copy src dir)))

(defn install-file-rule
  "Add install and uninstall rule for moving file from src into destdir."
  [src dest]
  (unless (check-release) (break))
  (array/push (dyn :installed-files) dest)
  (def dest1 (string (dyn :dest-dir "") dest))
  (r/task "install" []
          (sh/copyfile src dest1)))

(defn uninstall
  "Uninstall bundle named name"
  [name]
  (def manifest (sh/find-manifest name))
  (when-with [f (file/open manifest)]
    (def man (parse (:read f :all)))
    (each path (get man :paths [])
      (def path1 (string (dyn :dest-dir "") path))
      (print "removing " path1)
      (sh/rm path1))
    (print "removing manifest " manifest)
    (:close f) # I hate windows
    (sh/rm manifest)
    (print "Uninstalled.")))

(defn declare-native
  "Declare a native module. This is a shared library that can be loaded
  dynamically by a janet runtime. This also builds a static libary that
  can be used to bundle janet code and native into a single executable."
  [&keys opts]
  (def sources (opts :source))
  (def name (opts :name))
  (def path (string (cnf/dyn:modpath) "/" (sh/dirname name)))
  (def declare-targets @{})

  (def modext (cnf/dyn:modext))
  (def statext (cnf/dyn:statext))
  (def importlibext (dyn :importlibext nil))

  # Make dynamic module
  (def lname (string (sh/find-build-dir) name modext))

  # Get objects to build with
  (var has-cpp false)
  (def objects
    (seq [src :in sources]
      (def suffix
        (cond
          (string/has-suffix? ".cpp" src) ".cpp"
          (string/has-suffix? ".cc" src) ".cc"
          (string/has-suffix? ".c" src) ".c"
          (string/has-suffix? ".janet" src) ".janet"
          (errorf "unknown source file type: %s, expected .c, .cc, .cpp, or .janet" src)))
      (def op (cc/out-path src suffix ".o"))
      (case suffix
        ".c" (cc/compile-c :cc opts src op)
        ".janet" (do
                   (sh/create-dirs op)
                   (def csrc (cc/out-path src suffix ".c"))
                   (r/rule csrc [src] (dofile-codegen src csrc))
                   (cc/compile-c :cc opts csrc op))
        (do (cc/compile-c :c++ opts src op)
          (set has-cpp true)))
      op))

  (when-let [embedded (opts :embedded)]
    (loop [src :in embedded]
      (def c-src (cc/out-path src ".janet" ".janet.c"))
      (def o-src (cc/out-path src ".janet" ".janet.o"))
      (array/push objects o-src)
      (cc/create-buffer-c src c-src (cc/embed-name src))
      (cc/compile-c :cc opts c-src o-src)))
  (cc/link-c has-cpp opts lname ;objects)
  (put declare-targets :native lname)
  (r/add-dep "build" lname)
  (install-rule lname path)

  # Add meta file
  (def metaname (cc/modpath-to-meta lname))
  (def ename (cc/entry-name name))
  (r/rule metaname []
          (print "generating meta file " metaname "...")
          (flush)
          (os/mkdir (sh/find-build-dir))
          (sh/create-dirs metaname)
          (spit metaname (string/format
                           "# Metadata for static library %s\n\n%.20p"
                           (string name statext)
                           {:static-entry ename
                            :cpp has-cpp
                            :ldflags ~',(opts :ldflags)
                            :lflags ~',(opts :lflags)})))
  (r/add-dep "build" metaname)
  (put declare-targets :meta metaname)
  (install-rule metaname path)

  # Make static module
  (unless (dyn :nostatic)
    (def sname (string (sh/find-build-dir) name statext))
    (def impname (if importlibext (string (sh/find-build-dir) name importlibext) nil))
    (def opts (merge @{:entry-name ename} opts))
    (def sobjext ".static.o")
    (def sjobjext ".janet.static.o")

    # Get static objects
    (def sobjects
      (seq [src :in sources]
        (def suffix
          (cond
            (string/has-suffix? ".cpp" src) ".cpp"
            (string/has-suffix? ".cc" src) ".cc"
            (string/has-suffix? ".c" src) ".c"
            (string/has-suffix? ".janet" src) ".janet"
            (errorf "unknown source file type: %s, expected .c, .cc, .cpp, or .janet" src)))
        (def op (cc/out-path src suffix sobjext))
        (case suffix
          ".c" (cc/compile-c :cc opts src op true)
          ".janet" (do
                     (def csrc (cc/out-path src suffix ".c"))
                     (r/rule csrc [src] (dofile-codegen src csrc))
                     (cc/compile-c :cc opts csrc op true))
          (cc/compile-c :c++ opts src op true))
        # Add artificial dep between static object and non-static object - prevents double errors
        # when doing default builds.
        (r/add-dep op (cc/out-path src suffix ".o"))
        op))

    (when-let [embedded (opts :embedded)]
      (loop [src :in embedded]
        (def c-src (cc/out-path src ".janet" ".janet.c"))
        (def o-src (cc/out-path src ".janet" sjobjext))
        (array/push sobjects o-src)
        # Buffer c-src is already declared by dynamic module
        (cc/compile-c :cc opts c-src o-src true)))

    (cc/archive-c opts sname ;sobjects)
    (when (check-release)
      (r/add-dep "build" sname))
    (put declare-targets :static sname)
    (when impname
      (install-rule impname path))
    (install-rule sname path))

  declare-targets)

(defn declare-source
  "Create Janet modules. This does not actually build the module(s),
  but registers them for packaging and installation. :source should be an
  array of files and directores to copy into JANET_MODPATH or JANET_PATH.
  :prefix can optionally be given to modify the destination path to be
  (string JANET_PATH prefix source)."
  [&keys {:source sources :prefix prefix}]
  (def path (string (cnf/dyn:modpath) (if prefix "/") prefix))
  (if (bytes? sources)
    (install-rule sources path)
    (each s sources
      (install-rule s path)))
  (when prefix
    (array/push (dyn :installed-files) path)))

(defn declare-headers
  "Declare headers for a library installation. Installed headers can be used by other native
  libraries."
  [&keys {:headers headers :prefix prefix}]
  (def path (string (cnf/dyn:modpath) "/" (or prefix "")))
  (if (bytes? headers)
    (install-rule headers path)
    (each h headers
      (install-rule h path))))

(defn declare-bin
  "Declare a generic file to be installed as an executable."
  [&keys {:main main}]
  (install-rule main (cnf/dyn:binpath)))

(defn declare-executable
  "Declare a janet file to be the entry of a standalone executable program. The entry
  file is evaluated and a main function is looked for in the entry file. This function
  is marshalled into bytecode which is then embedded in a final executable for distribution.\n\n
  This executable can be installed as well to the --binpath given."
  [&keys {:install install :name name :entry entry :headers headers
          :cflags cflags :lflags lflags :deps deps :ldflags ldflags
          :no-compile no-compile :no-core no-core}]
  (def name (if (sh/is-win-or-mingw) (string name ".exe") name))
  (def dest (string (sh/find-build-dir) name))
  (cc/create-executable @{:cflags cflags :lflags lflags :ldflags ldflags :no-compile no-compile} entry dest no-core)
  (if no-compile
    (let [cdest (string dest ".c")]
      (r/add-dep "build" cdest))
    (do
      (r/add-dep "build" dest)
      (when headers
        (each h headers (r/add-dep dest h)))
      (when deps
        (each d deps (r/add-dep dest d)))
      (when install
        (install-rule dest (cnf/dyn:binpath))))))

(defn declare-binscript
  ``Declare a janet file to be installed as an executable script. Creates
  a shim on windows. If hardcode is true, will insert code into the script
  such that it will run correctly even when JANET_PATH is changed. if auto-shebang
  is truthy, will also automatically insert a correct shebang line.
  ``
  [&keys {:main main :hardcode-syspath hardcode :is-janet is-janet}]
  (def binpath (cnf/dyn:binpath))
  (def auto-shebang (and is-janet (cnf/dyn:auto-shebang)))
  (if (or auto-shebang hardcode)
    (let [syspath (cnf/dyn:modpath)]
      (def parts (peg/match sh/path-splitter main))
      (def name (last parts))
      (def path (string binpath "/" name))
      (array/push (dyn :installed-files) path)
      (r/task "install" []
              (def contents
                (with [f (file/open main :rbn)]
                  (def first-line (:read f :line))
                  (def second-line (string/format "(put root-env :syspath %v)\n" syspath))
                  (def rest (:read f :all))
                  (string (if auto-shebang
                            (string "#!" (cnf/dyn:binpath) "/janet\n"))
                          first-line (if hardcode second-line) rest)))
              (def destpath (string (dyn :dest-dir "") path))
              (sh/create-dirs destpath)
              (print "installing " main " to " destpath)
              (spit destpath contents)
              (unless (sh/is-win-or-mingw) (sh/shell "chmod" "+x" destpath))))
    (install-rule main binpath))
  # Create a dud batch file when on windows.
  (when (sh/is-win-or-mingw)
    (def name (last (peg/match sh/path-splitter main)))
    (def fullname (string binpath "/" name))
    (def bat (string "@echo off\r\ngoto #_undefined_# 2>NUL || title %COMSPEC% & janet \"" fullname "\" %*"))
    (def newname (string binpath "/" name ".bat"))
    (array/push (dyn :installed-files) newname)
    (r/task "install" []
            (spit (string (dyn :dest-dir "") newname) bat))))

(defn declare-archive
  "Build a janet archive. This is a file that bundles together many janet
  scripts into a janet image. This file can the be moved to any machine with
  a janet vm and the required dependencies and run there."
  [&keys opts]
  (def entry (opts :entry))
  (def name (opts :name))
  (def iname (string (sh/find-build-dir) name ".jimage"))
  (r/rule iname (or (opts :deps) [])
          (sh/create-dirs iname)
          (spit iname (make-image (require entry))))
  (def path (cnf/dyn:modpath))
  (r/add-dep "build" iname)
  (install-rule iname path))

(defn declare-manpage
  "Mark a manpage for installation"
  [page]
  (when-let [mp (dyn :manpath)]
    (install-rule page mp)))

(defn run-tests
  "Run tests on a project in the current directory. The tests will
  be run in the environment dictated by (dyn :modpath)."
  [&opt root-directory]
  (var errors-found 0)
  (defn dodir
    [dir]
    (each sub (sort (os/dir dir))
      (def ndir (string dir "/" sub))
      (case (os/stat ndir :mode)
        :file (when (string/has-suffix? ".janet" ndir)
                (print "running " ndir " ...")
                (flush)
                (def result (sh/run-script ndir))
                (when (not= 0 result)
                  (++ errors-found)
                  (eprinf (sh/color :red "non-zero exit code in %s: ") ndir)
                  (eprintf "%d" result)))
        :directory (dodir ndir))))
  (dodir (or root-directory "test"))
  (if (zero? errors-found)
    (print (sh/color :green "✓ All tests passed."))
    (do
      (prin (sh/color :red "✘ Failing test scripts: "))
      (printf "%d" errors-found)
      (os/exit 1)))
  (flush))

(defn declare-project
  "Define your project metadata. This should
  be the first declaration in a project.janet file.
  Also sets up basic task targets like clean, build, test, etc."
  [&keys meta]
  (setdyn :project (struct/to-table meta))

  (def installed-files @[])
  (def manifests (sh/find-manifest-dir))
  (def manifest (sh/find-manifest (meta :name)))
  (setdyn :manifest manifest)
  (setdyn :manifest-dir manifests)
  (setdyn :installed-files installed-files)

  (r/task "build" [])

  (unless (check-release)
    (r/task "install" []
            (print "The install target is only enabled for release builds.")
            (os/exit 1)))

  (when (check-release)

    (r/task "manifest" [manifest])
    (r/rule manifest ["uninstall"]
            (print "generating " manifest "...")
            (flush)
            (os/mkdir manifests)
            (def has-git (os/stat ".git" :mode))
            (def bundle-type (dyn :bundle-type (if has-git :git :local)))
            (def man
              @{:dependencies (array/slice (get meta :dependencies []))
                :version (get meta :version "0.0.0")
                :paths installed-files
                :type bundle-type})
            (case bundle-type
              :git
              (do
                (if-let [shallow (dyn :shallow)]
                  (put man :shallow shallow))
                (protect
                  (if-let [x (sh/exec-slurp (cnf/dyn:gitpath) "remote" "get-url" "origin")]
                    (put man :url (if-not (empty? x) x))))
                (protect
                  (if-let [x (sh/exec-slurp (cnf/dyn:gitpath) "rev-parse" "HEAD")]
                    (put man :tag (if-not (empty? x) x)))))
              :tar
              (do
                (put man :url (slurp ".bundle-tar-url")))
              :local nil
              (errorf "unknown bundle type %v" bundle-type))
            (spit manifest (string/format "%j\n" (table/to-struct man))))

    (r/task "install" ["uninstall" "build" manifest]
            (when (dyn :test)
              (run-tests))
            (print "Installed as '" (meta :name) "'.")
            (flush))

    (r/task "uninstall" []
            (uninstall (meta :name))))

  (r/task "clean" []
          # cut off trailing path separator (needed in msys2)
          (def bd (string/slice (sh/find-build-dir) 0 -2))
          (when (os/stat bd :mode)
            (sh/rm bd)
            (print "Deleted build directory " bd)
            (flush)))

  (r/task "test" ["build"]
          (run-tests)))
