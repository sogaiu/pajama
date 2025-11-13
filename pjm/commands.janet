###
### All of the CLI sub commands
###

(import ./config :as cnf)
(import ./declare :as decl)
(import ./rules :as r)
(import ./shutil :as sh)
(import ./cc)
(import ./pm)
(import ./scaffold :as scf)

(defn help
  []
  (print
    ```
    usage: pjm [--key=value, --flag] ... [subcommand] [args] ...

    Run from a directory containing a project.janet file to perform
    operations on a project, or from anywhere to do operations on the
    global module cache (modpath).  Commands that need write permission
    to the modpath are considered privileged commands - in some
    environments they may require super user privileges.  Other
    project-level commands need to have a ./project.janet file in the
    current directory.

    To install/manage packages in a local subtree, use the --local flag
    (or -l) to install packages to ./pjm_tree. This should generally not
    require elevated privileges.

    Unprivileged global subcommands:

        help
            Show this help text.

        show-paths
            Prints the paths that will be used to install things.

        quickbin entry executable
            Create an executable from a janet script with a main function.

        exec
            Run any shell command with JANET_PATH set to the correct
            module tree.

        janet
            Run the Janet interpreter with JANET_PATH set to the correct
            module tree.

        new-project name
            Create a new Janet project in a directory `name`.

        new-c-project name
            Create a new C+Janet project in a directory `name`.

        new-exe-project name
            Create a new project for an executable in a directory `name`.

    Privileged global subcommands:

        install (repo or name)...
            Install artifacts. If a repo is given, install the contents
            of that git repository, assuming that the repository is a
            pjm project. If not, build and install the current project.

        update-installed
            Reinstall all installed packages. For packages that are not
            pinned to a specific version, this will get that latest
            version of packages.

        uninstall (module)...
            Uninstall a module. If no module is given, uninstall the
            module defined by the current directory.

        clear-cache
            Clear the git cache. Useful for updating dependencies.

        clear-manifest
            Clear the manifest. Useful for fixing broken installs.

        make-lockfile (lockfile)
            Create a lockfile based on repositories in the cache. The
            lockfile will record the exact versions of dependencies used
            to ensure a reproducible build. Lockfiles are best used with
            applications, not libraries. The default lockfile name is
            lockfile.jdn.

        load-lockfile (lockfile)
            Install modules from a lockfile in a reproducible way. The
            default lockfile name is lockfile.jdn.

        update-pkgs
            Update the current package listing from the remote git
            repository selected.

    Privileged project subcommands:

        deps
            Install dependencies for the current project.

        install
            Install artifacts of the current project.

        uninstall
            Uninstall the current project's artifacts.

    Unprivileged project subcommands:

        build
            Build all artifacts in the build/ directory, or the value
            specified in --buildpath.

        configure path
            Create a directory for out-of-tree builds, and also set
            project options.

        clean
            Remove any generated files or artifacts.

        test
            Run tests. Tests should be .janet files in the test/ directory
            relative to project.janet. Will patch the module paths to load
            built native code without installing it.

        run rule
            Run a rule. Can also run custom rules added via `(phony "task"
            [deps...] ...)` or `(rule "ouput.file" [deps...] ...)`.

        rules
            List rules available with run.

        list-installed
            List installed packages in the current syspath.

        list-pkgs (search)
            List packages in the package listing that the contain the
            string search.  If no search pattern is given, prints the
            entire package listing.

        rule-tree (root rule) (depth)
            Print a nice tree to see what rules depend on other rules.
            Optionally provide a root rule to start printing from, and a
            max depth to print. Without these options, all rules will
            print their full dependency tree.

        repl
            Run a repl in the same environment as the test environment.
            Allows you to use built natives without installing them.

        debug-repl
            Run a repl in the context of the current project.janet
            file. This lets you run rules and otherwise debug the current
            project.janet file.

        save-config path
            Save the input configuration to a file.
    ```)

  (print)
  (print "Global options:")
  (each k (sort (keys cnf/config-docs))
    (when (cnf/builtin-configs k)
      (print "  --" k " : " (get cnf/config-docs k))))
  (unless (= (length cnf/config-docs) (length cnf/builtin-configs))
    (print)
    (print "Project options:")
    (each k (sort (keys cnf/config-docs))
      (unless (cnf/builtin-configs k)
        (print "  --" k " : " (get cnf/config-docs k)))))
  (print))

(defn- local-rule
  [rule &opt no-deps]
  (pm/import-rules "./project.janet" @{:pjm-no-deps no-deps})
  (pm/do-rule rule))

(defn show-config
  []
  (def configs (sorted (keys cnf/config-set)))
  (each conf configs
    (printf (if (dyn :nocolor) ":%-26s%.99q" ":%-26s%.99Q")
            (string conf) (dyn conf))))

(defn show-paths
  []
  (print "tree:       " (dyn :tree))
  (print "binpath:    " (cnf/dyn:binpath))
  (print "modpath:    " (cnf/dyn:modpath))
  (print "syspath:    " (dyn :syspath))
  (print "manpath:    " (dyn :manpath))
  (print "libpath:    " (cnf/dyn:libpath))
  (print "headerpath: " (cnf/dyn:headerpath))
  (print "buildpath:  " (dyn :buildpath "build/"))
  (print "gitpath:    " (dyn :gitpath))
  (print "tarpath:    " (dyn :tarpath))
  (print "curlpath:   " (dyn :curlpath)))

(defn build
  []
  (local-rule "build"))

(defn clean
  []
  (local-rule "clean"))

(defn install
  [& repo]
  (if (empty? repo)
    (local-rule "install")
    (each rep repo (pm/bundle-install rep))))

(defn test
  []
  (local-rule "test"))

(defn- uninstall-cmd
  [& what]
  (if (empty? what)
    (local-rule "uninstall")
    (each wha what (decl/uninstall wha))))

(defn deps
  []
  (def env (pm/import-rules "./project.janet" @{:pjm-no-deps true}))
  (def meta (get env :project))
  (if-let [deps (meta :dependencies)]
    (each dep deps
      (pm/bundle-install dep))
    (do (print "no dependencies found") (flush))))

(defn- print-rule-tree
  "Show dependencies for a given rule recursively in a nice tree."
  [root depth prefix prefix-part]
  (print prefix root)
  (when-let [{:inputs root-deps} ((r/getrules) root)]
    (when (pos? depth)
      (def l (-> root-deps length dec))
      (eachp [i d] (sorted root-deps)
        (print-rule-tree
          d (dec depth)
          (string prefix-part (if (= i l) " └─" " ├─"))
          (string prefix-part (if (= i l) "   " " │ ")))))))

(defn show-rule-tree
  [&opt root depth]
  (pm/import-rules "./project.janet")
  (def max-depth (if depth (scan-number depth) math/inf))
  (if root
    (print-rule-tree root max-depth "" "")
    (let [ks (sort (seq [k :keys (dyn :rules)] k))]
      (each k ks (print-rule-tree k max-depth "" "")))))

(defn list-rules
  [&opt ctx]
  (pm/import-rules "./project.janet")
  (def ks (sort (seq [k :keys (dyn :rules)] k)))
  (each k ks (print k)))

(defn list-tasks
  [&opt ctx]
  (pm/import-rules "./project.janet")
  (def ts
    (sort (seq [[t r] :pairs (dyn :rules)
                :when (get r :task)]
            t)))
  (each t ts (print t)))

(defn list-installed
  []
  (def xs
    (seq [x :in (os/dir (sh/find-manifest-dir))
          :when (string/has-suffix? ".jdn" x)]
      (string/slice x 0 -5)))
  (sort xs)
  (each x xs (print x)))

(defn list-pkgs
  [&opt search]
  (def [ok _] (module/find "pkgs"))
  (unless ok
    (eprint "no local package listing found. Run `pjm update-pkgs` to get listing.")
    (os/exit 1))
  (def pkgs-mod (require "pkgs"))
  (def ps
    (seq [p :keys (get-in pkgs-mod ['packages :value] [])
          :when (if search (string/find search p) true)]
      p))
  (sort ps)
  (each p ps (print p)))

(defn update-pkgs
  []
  (pm/bundle-install (cnf/dyn:pkglist) false true))

(defn quickbin
  [input output]
  (when (= (os/stat output :mode) :file)
    (print "output " output " exists."))
  (cc/create-executable @{:no-compile (dyn :no-compile)} input output (dyn :no-core))
  (pm/do-rule output))

(defn pjm-debug-repl
  []
  (def env
    (try
      (pm/require-pjm "./project.janet")
      ([err f]
        (if (= "cannot open ./project.janet" err)
          (put (pm/make-pjm-env) :project {})
          (propagate err f)))))
  (setdyn :pretty-format (if-not (dyn :nocolor) "%.20Q" "%.20q"))
  (setdyn :err-color (unless (dyn :nocolor) true))
  (def p (env :project))
  (def name (p :name))
  (when name (print "Project:     " name))
  (when-let [r (p :repo)] (print "Repository:  " r))
  (when-let [a (p :author)] (print "Author:      " a))
  (defn getchunk [buf p]
    (def [line] (parser/where p))
    (getline (string "pjm[" (or name "repl") "]:"
                     line ":"
                     (parser/state p :delimiters) "> ")
             buf env))
  (repl getchunk nil env))

(defn set-tree
  ``
  Set the module tree for installing dependencies. This just sets
  the modpath, binpath, and manpath. Also creates the tree if it
  doesn't exist. However, still uses the system libraries and
  headers for janet.
  ``
  [tree]
  (def abs-tree (sh/abspath tree))
  (def sep (if (sh/is-win) "\\" "/"))
  (def tree-bin (string abs-tree sep "bin"))
  (def tree-lib (string abs-tree sep "lib"))
  (def tree-man (string abs-tree sep "man"))
  (os/mkdir abs-tree)
  (os/mkdir tree-bin)
  (os/mkdir tree-lib)
  (os/mkdir tree-man)
  (setdyn :manpath tree-man)
  (setdyn :binpath tree-bin)
  (setdyn :modpath tree-lib))

(defn enable-local-mode
  ``
  Modify the config to enable local development. Creates a local tree
  if one does not exist in `./pjm_tree/`.
  ``
  []
  (set-tree "pjm_tree"))

(defn configure
  "Setup an out-of-tree build with certain configuration options."
  [&opt path]
  (def opts @{})
  (def module (pm/require-pjm "./project.janet" @{:pjm-no-deps true}))
  (eachk key cnf/config-set
    (put opts key (dyn key)))
  (default path (string "_" (dyn :build-type "out")))
  (pm/out-of-tree-config path opts))

(defn new-project
  "Create a new project."
  [name]
  (scf/scaffold-project name {:c false}))

(defn new-c-project
  "Create a new C project."
  [name]
  (scf/scaffold-project name {:c true}))

(defn new-exe-project
  "Create a new executable project."
  [name]
  (scf/scaffold-project name {:c false :exe true}))

(def subcommands
  {"build" build
   "clean" clean
   "help" help
   "install" install
   "test" test
   "help" help
   "deps" deps
   "debug-repl" pjm-debug-repl
   "rule-tree" show-rule-tree
   "show-paths" show-paths
   "show-config" show-config
   "list-installed" list-installed
   "list-pkgs" list-pkgs
   "clear-cache" sh/clear-cache
   "clear-manifest" sh/clear-manifest
   "repl" sh/run-repl
   "run" local-rule
   "rules" list-rules
   "tasks" list-tasks
   "update-pkgs" update-pkgs
   "update-installed" pm/update-installed
   "uninstall" uninstall-cmd
   "make-lockfile" pm/make-lockfile
   "load-lockfile" pm/load-lockfile
   "quickbin" quickbin
   "configure" configure
   "exec" sh/shell
   "new-project" new-project
   "new-c-project" new-c-project
   "new-exe-project" new-exe-project
   "janet" (fn [& args] (sh/shell (dyn :executable) ;args))
   "save-config" cnf/save-config})
