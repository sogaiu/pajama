###
### Package management functionality
###

(import ./config :as cnf)
(import ./shutil :as sh)
(import ./rules :as r)

(defn- proto-flatten
  [into x]
  (when x
    (proto-flatten into (table/getproto x))
    (merge-into into x))
  into)

(def- mod-rules (require "./rules"))
(def- mod-shutil (require "./shutil"))
(def- mod-cc (require "./cc"))
(def- mod-cgen (require "./cgen"))
(def- mod-declare (require "./declare"))
(def- mod-make-config (require "./make-config"))
(def- mod-pm (curenv))

(defn make-pjm-env
  "Create an environment that is preloaded with pjm symbols."
  [&opt base-env]
  (def envs-to-add
    [mod-declare
     mod-shutil
     mod-rules
     mod-cc
     mod-cgen
     mod-pm
     mod-make-config])
  (def env (make-env))
  (loop [e :in envs-to-add
         k :keys e :when (symbol? k)
         :let [x (get e k)]]
    (unless (get x :private)
      (put env k x)))
  (def currenv (proto-flatten @{} (curenv)))
  (loop [k :keys currenv :when (keyword? k)]
    (put env k (currenv k)))
  # For compatibility reasons
  (when base-env
    (merge-into env base-env))
  (put env 'default-cflags @{:value (cnf/dyn:cflags)})
  (put env 'default-lflags @{:value (cnf/dyn:lflags)})
  (put env 'default-ldflags @{:value (cnf/dyn:ldflags)})
  (put env 'default-cppflags @{:value (cnf/dyn:cppflags)})
  (put env :syspath (cnf/dyn:modpath))
  env)

(defn require-pjm
  ``
  Require a pjm file project file. This is different from a normal
  require in that code is loaded in the pjm environment.
  ``
  [path &opt base-env]
  (unless (os/stat path :mode)
    (error (string "cannot open " path)))
  (def env (make-pjm-env base-env))
  (dofile path :env env :exit true)
  env)

(defn load-project-meta
  ``
  Load the metadata from a project.janet file without doing a full
  evaluation of the project.janet file. Returns a struct with the
  project metadata. Raises an error if no metadata found.
  ``
  [&opt path]
  (default path "./project.janet")
  (def src (slurp path))
  (def p (parser/new))
  (parser/consume p src)
  (parser/eof p)
  (var ret nil)
  (while (parser/has-more p)
    (when ret (break))
    (def item (parser/produce p))
    (match item
      ['declare-project & rest] (set ret (struct ;rest))))
  (unless ret
    (errorf "no metadata found in %s" path))
  ret)

(defn import-rules
  ``
  Import another file that defines more rules. This ruleset is
  merged into the current ruleset.
  ``
  [path &opt base-env]
  (def env (require-pjm path base-env))
  (when-let [rules (get env :rules)] (merge-into (r/getrules) rules))
  (when-let [project (get env :project)]
    (setdyn :project (merge-into (dyn :project @{}) project)))
  env)

(defn git
  "Make a call to git."
  [& args]
  (sh/shell (cnf/dyn:gitpath) ;args))

(defn tar
  "Make a call to tar."
  [& args]
  (sh/shell (cnf/dyn:tarpath) ;args))

(defn curl
  "Make a call to curl"
  [& args]
  (sh/shell (cnf/dyn:curlpath) ;args))

(var- bundle-install-recursive nil)

(defn- resolve-bundle-name
  "Convert short bundle names to full dictionaries."
  [bname]
  (if-not (string/find ":" bname)
    (let [pkgs (try
                 (require "pkgs")
                 ([err]
                   (bundle-install-recursive (cnf/dyn:pkglist))
                   (require "pkgs")))
          url (get-in pkgs ['packages :value (symbol bname)])]
      (unless url
        (error (string "bundle " bname " not found.")))
      url)
    bname))

(defn resolve-bundle
  "Convert any bundle string/table to the normalized dictionary form."
  [bundle]
  (var repo nil)
  (var tag nil)
  (var btype :git)
  (var shallow false)
  (if (dictionary? bundle)
    (do
      (set repo (or (get bundle :url) (get bundle :repo)))
      (set tag (or (get bundle :tag) (get bundle :sha) (get bundle :commit) (get bundle :ref)))
      (set btype (get bundle :type :git))
      (set shallow (get bundle :shallow false)))
    (let [parts (string/split "::" bundle)]
      (case (length parts)
        1 (set repo (get parts 0))
        2 (do (set repo (get parts 1)) (set btype (keyword (get parts 0))))
        3 (do
            (set btype (keyword (get parts 0)))
            (set repo (get parts 1))
            (set tag (get parts 2)))
        (errorf "unable to parse bundle string %v" bundle))))
  {:url (resolve-bundle-name repo) :tag tag :type btype :shallow shallow})

(comment

  (resolve-bundle "https://github.com/janet-lang/spork")
  # =>
  {:shallow false
   :type :git
   :url "https://github.com/janet-lang/spork"}

  (resolve-bundle {:tag "e939a040f7183a518d9b396d017e1773e228a4c3"
                   :url "https://github.com/janet-lang/spork"})
  # =>
  {:shallow false
   :tag "e939a040f7183a518d9b396d017e1773e228a4c3"
   :type :git
   :url "https://github.com/janet-lang/spork"}

  (resolve-bundle (string "git::"
                          "https://github.com/janet-lang/spork::"
                          "e939a040f7183a518d9b396d017e1773e228a4c3"))
  # =>
  {:shallow false
   :tag "e939a040f7183a518d9b396d017e1773e228a4c3"
   :type :git
   :url "https://github.com/janet-lang/spork"}

  )

(defn update-git-bundle
  "Fetch latest tag version from remote repository"
  [bundle-dir tag shallow]
  (if shallow
    (git "-C" bundle-dir "fetch" "--depth" "1" "origin" (or tag "HEAD"))
    (do
      # Tag can be a hash, e.g. in lockfile. Some Git servers don't allow
      # fetching arbitrary objects by hash. First fetch ensures, that we have
      # all objects locally.
      (git "-C" bundle-dir "fetch" "--tags" "origin")
      (git "-C" bundle-dir "fetch" "origin" (or tag "HEAD"))))
  (git "-C" bundle-dir "reset" "--hard" "FETCH_HEAD"))

(defn download-git-bundle
  "Download a git bundle from a remote respository."
  [bundle-dir url tag shallow]
  (var fresh false)
  (if (dyn :offline)
    (if (not= :directory (os/stat bundle-dir :mode))
      (error (string "did not find cached repository for dependency " url))
      (set fresh true))
    (when (os/mkdir bundle-dir)
      (set fresh true)
      (git "-c" "init.defaultBranch=master" "-C" bundle-dir "init")
      (git "-C" bundle-dir "remote" "add" "origin" url)
      (update-git-bundle bundle-dir tag shallow)))
  (unless (or (dyn :offline) fresh)
    (update-git-bundle bundle-dir tag shallow))
  (unless (dyn :offline)
    (git "-C" bundle-dir "submodule" "update" "--init" "--recursive")))

(defn download-tar-bundle
  ``
  Download a dependency from a tape archive. The archive should
  have exactly one top level directory containing the contents of
  the project.
  ``
  [bundle-dir url &opt force-gz]
  (def has-gz (string/has-suffix? "gz" url))
  (def is-remote (string/find ":" url))
  (def dest-archive (if is-remote (string bundle-dir "/bundle-archive." (if has-gz "tar.gz" "tar")) url))
  (os/mkdir bundle-dir)
  (when is-remote
    (curl "-sL" url "--output" dest-archive))
  (spit (string bundle-dir "/.bundle-tar-url") url)
  (def tar-flags (if has-gz "-xzf" "-xf"))
  (tar tar-flags dest-archive "--strip-components=1" "-C" bundle-dir))

(defn download-bundle
  ``
  Download the package source (using git) to the local cache.
  Return the path to the downloaded or cached soure code.
  ``
  [url bundle-type &opt tag shallow]
  (def cache (sh/find-cache))
  (os/mkdir cache)
  (def id (sh/filepath-replace (string bundle-type "_" tag "_" url)))
  (def bundle-dir (string cache "/" id))
  (case bundle-type
    :git (download-git-bundle bundle-dir url tag shallow)
    :tar (download-tar-bundle bundle-dir url)
    (errorf "unknown bundle type %v" bundle-type))
  bundle-dir)

(var- installed-bundle-index nil)
(defn is-bundle-installed
  "Determines if a bundle has been installed or not"
  [bundle]
  # initialize bundle index
  (unless installed-bundle-index
    (set installed-bundle-index @{})
    (os/mkdir (sh/find-manifest-dir))
    (each manifest (os/dir (sh/find-manifest-dir))
      (def bundle-data (parse (slurp (string (sh/find-manifest-dir) "/" manifest))))
      (def {:url u :repo r :tag s :type t :shallow a} bundle-data)
      (put installed-bundle-index (or u r) {:tag s
                                            :type t
                                            :shallow (not (nil? a))})))
  (when-let [installed-bundle (get installed-bundle-index (bundle :url))]
    (def {:type bt :tag bs} bundle)
    (def {:type it :tag is} installed-bundle)
    (and
      (or (not bt) (= bt it))
      (or (not bs) (= bs is)))))

(defn bundle-install
  "Install a bundle from a git repository."
  [bundle &opt no-deps force-update]
  (def bundle (resolve-bundle bundle))
  (when (or (not (is-bundle-installed bundle)) force-update)
    (def {:url url
          :tag tag
          :type bundle-type
          :shallow shallow}
      bundle)
    (def bdir (download-bundle url bundle-type tag shallow))
    (def olddir (os/cwd))
    (defer (os/cd olddir)
      (os/cd bdir)
      (with-dyns [:rules @{}
                  :bundle-type (or bundle-type :git)
                  :shallow shallow
                  :buildpath "build/" # reset build path to default
                  :modpath (sh/abspath (cnf/dyn:modpath))
                  :workers (dyn :workers)
                  :headerpath (sh/abspath (cnf/dyn:headerpath))
                  :libpath (sh/abspath (cnf/dyn:libpath))
                  :binpath (sh/abspath (cnf/dyn:binpath))]
        (def dep-env (require-pjm "./project.janet" @{:pjm-no-deps true}))
        (unless no-deps
          (def meta (dep-env  :project))
          (when-let [deps (meta :dependencies)]
            (each dep deps
              (bundle-install dep))))
        (each r ["build" "install"]
          (r/build-rules (get dep-env :rules {}) [r]))
        (put installed-bundle-index url bundle)))))

(set bundle-install-recursive bundle-install)

(defn make-lockfile
  [&opt filename]
  (default filename "lockfile.jdn")
  (def cwd (os/cwd))
  (def packages @[])
  # Read installed modules from manifests
  (def mdir (sh/find-manifest-dir))
  (each man (os/dir mdir)
    (def package (parse (slurp (string mdir "/"  man))))
    (if (and (dictionary? package) (or (package :url) (package :repo)))
      (array/push packages package)
      (print "Cannot add local or malformed package " mdir "/" man " to lockfile, skipping...")))

  # Scramble to simulate runtime randomness (when trying to repro, order can
  # be remarkably stable) - see janet-lang/janet issue #1082
  # (def rand-thing (string (os/cryptorand 16)))
  # (sort-by |(hash [rand-thing (get $ :url)]) packages)

  # Sort initially by package url to make stable
  (sort-by |[(get $ :url) (get $ :repo)] packages)

  # Put in correct order, such that a package is preceded by all of its dependencies
  (def ordered-packages @[])
  (def resolved @{})
  (while (< (length ordered-packages) (length packages))
    (print "step")
    (var made-progress false)
    (each p packages
      (def {:url u :repo r :tag s :dependencies d :type t :shallow a} p)
      (def key (in (resolve-bundle p) :url))
      (def dep-bundles (map |(in (resolve-bundle $) :url) d))
      (unless (resolved key)
        (when (all resolved dep-bundles)
          (print "item: " (or u r))
          (array/push ordered-packages {:url (or u r) :tag s :type t :shallow a})
          (set made-progress true)
          (put resolved key true))))
    (unless made-progress
      (error (string/format "could not resolve package order for: %j"
                            (filter (complement resolved) (map |(or ($ :url) ($ :repo)) packages))))))
  # Write to file, manual format for better diffs.
  (with [f (file/open filename :wn)]
    (with-dyns [:out f]
      (prin "@[")
      (eachk i ordered-packages
        (unless (zero? i)
          (prin "\n  "))
        (prinf "%j" (ordered-packages i)))
      (print "]")))
  (print "created " filename))

(defn load-lockfile
  "Load packages from a lockfile."
  [&opt filename]
  (default filename "lockfile.jdn")
  (def lockarray (parse (slurp filename)))
  (each bundle lockarray
    (bundle-install bundle true)))

(defmacro post-deps
  "Run code at the top level if pjm dependencies are installed. Build
  code that imports dependencies should be wrapped with this macro, as project.janet
  needs to be able to run successfully even without dependencies installed."
  [& body]
  (unless (dyn :pjm-no-deps)
    ~',(reduce |(eval $1) nil body)))

(defn do-rule
  "Evaluate a given rule in a one-off manner."
  [target]
  (r/build-rules (dyn :rules) [target] (dyn :workers)))

(defn update-installed
  "Update all previously installed packages to their latest versions."
  []
  (def to-update (os/dir (sh/find-manifest-dir)))
  (var updated-count 0)
  (each p to-update
    (def bundle-data (parse (slurp (string (sh/find-manifest-dir) "/" p))))
    (def new-bundle (merge-into @{} bundle-data))
    (put new-bundle :tag nil)
    (try
      (do
        (bundle-install new-bundle true true)
        (++ updated-count))
      ([err f]
        (debug/stacktrace f err (string "unable to update dependency " p ": ")))))
  (print "updated " updated-count " of " (length to-update) " installed packages")
  (unless (= updated-count (length to-update))
    (error "could not update all installed packages")))

(defn out-of-tree-config
  "Create an out of tree build configuration. This lets a user have a debug or release build, as well
  as other configuration on a one time basis. This works by creating a new directory with
  a project.janet that loads in the original project.janet file with some settings changed."
  [path &opt options]
  (def current (sh/abspath (os/cwd)))
  (def options (merge-into @{} options))
  (def new-build-path (string path "/build/"))
  (put options :buildpath new-build-path)
  (def dest (string path "/project.janet"))
  (def odest (string path "/options.janet"))
  (print "creating out of tree build at " (sh/abspath path))
  (sh/create-dirs dest)
  (spit odest
        (string/join
          (map |(string/format "(setdyn %v %j)" ($ 0) ($ 1))
               (sorted (pairs options)))
          "\n"))
  (spit dest
        (string/format
          ```
          (os/cd %v)
          (import-rules "./project.janet")
          ```
          current)))
