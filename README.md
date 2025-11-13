This repository houses source code for `jpm` with some modifications.
ATM, its primary purpose is for study.  The name has been changed to
`pjm` so that it is possible to use this alongside `jpm`.

Pretty much all of the code comes from
[jpm](https://github.com/janet-lang/jpm) by bakpakin and contributors.

---

Depending on one's setup, it may be necessary for `PREFIX` to be set
for tests to execute successfully, e.g.:

```
$ PREFIX=$HOME/.local jpm test
```

or:

```
$ PREFIX=$HOME/.local pjm test
```

or:

```
$ PREFIX=$HOME/.local jeep test
```

