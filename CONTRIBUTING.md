# Contributing

The architecture, the house style, the release pipeline and every workflow live at
<https://token-menu-bar-macos.readthedocs.io/en/latest/contributing/>.

The short version, from a fresh checkout:

```sh
mise install   # hugo, just, pre-commit, xcodegen
just           # the list of workflows
just check     # build, tests with the coverage gate, every lint hook
```

`just check` covers what CI runs as `just lint` and `just coverage`, so a green one on your Mac means a green pull
request. To report a bug, use Settings > About > **Report Issue**, which fills the issue in for you. For a
vulnerability, read [SECURITY.md](SECURITY.md) first.
