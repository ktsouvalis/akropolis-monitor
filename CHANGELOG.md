# Changelog

All notable changes to akropolis-monitor are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Everything before 1.0.0 was developed in-tree without git tags, as a set of
loose scripts under the repository names `ak-monitor` and then `authentik`.
That history is in `git log`; it is not reproduced here.

## [Unreleased]

## [1.0.0] - 2026-09-07

First tagged release, and the point at which this repository stops being a
folder of scripts and becomes an installable package with a single entry
point. There is no behaviour change to any check, panel, or log query: the
dashboard polls what it always polled and the log viewer fetches what it
always fetched. What changed is how the code is arranged, invoked, and
shipped.

### Added

- `akropolis_monitor` package with one console script, `akropolis-monitor`,
  exposing two subcommands: `dashboard` and `logs`.
- Single-file zipapp distribution built by `tools/build_pyz.sh`, matching
  akropolis. One executable, no install step, no virtualenv.
- Tag-triggered release workflow publishing the zipapp, a wheel, an sdist,
  `THIRD_PARTY_LICENSES.md`, and `SHA256SUMS`.
- `THIRD_PARTY_LICENSES.md`, generated at build time from the bundled
  dependencies' own metadata rather than hand-maintained, indexing each
  vendored package's declared license and where its full text lives inside
  the archive. paramiko (LGPL-2.1) is the one bundled dependency that is not
  permissively licensed.
- CI now fails the release if any package named in that manifest has no
  license file, or names one that is not actually present in the archive.
  akropolis shipped a v1.0.1 binary whose dist-info filter silently deleted
  mdurl's bare top-level `LICENSE`; the manifest still claimed it. This check
  is that bug, turned into a gate.
- CI and the build script both assert that no compiled object survived the
  strip. That defect produces an artifact that works on the build host and
  fails everywhere else, which is the worst way for it to be found.
- `LICENSE` (MIT), matching akropolis. The repository previously had none.

### Changed

- `monitor.py` became `akropolis_monitor/dashboard.py`. Its config no longer
  loads at import time from `sys.argv`; `load_site(path)` populates the
  module globals, and `run(path)` calls it before starting the app. Importing
  the module no longer requires a config file to exist, which is what lets
  `cli.py` route to it.
- `logs_viewer.py` became `akropolis_monitor/logs.py`, split into `run()`
  (does the work, takes plain arguments) and `main()` (argparse only), so the
  CLI can call the former without going through argv.
- `dashboard` takes its config as a bare positional path and `logs` takes
  `--config`, preserving both tools' existing spellings rather than unifying
  them. See CLAUDE.md for why.
- Em dashes removed from prose, comments, and output strings throughout, with
  two deliberate exceptions: the single-character placeholder glyphs the
  dashboard renders for "no data", and `import_users.py`.
- `requirements.txt` now points at `pip install -e .` instead of duplicating
  the dependency list that `pyproject.toml` owns.

### Fixed

- The dashboard's terminal title showed the default site name instead of the
  configured one. `App.TITLE` was assigned in the class body, which is
  evaluated at import time, before any config has been read. Latent before
  this release, because config loading used to happen at import time too;
  moving it into `load_site()` would have exposed it.
- The status bar's initial dot ignored `unicode_bullets: false` and rendered
  `●` on terminals that asked for `*`, for the same class of reason: a
  `reactive(GREY)` default in a class body is frozen before the config that
  governs it has been read.
- The build script's compiled-object strip matches `*.so*`, not `*.so`.
  `psycopg2-binary` vendors roughly sixteen shared objects named like
  `libpq-f521cc7d.so.5.17`, none of which end in `.so`; a `*.so` sweep walks
  past every one of them and bundles them silently.
- `config.yml.example` told the reader to copy it to `config.yaml`, which no
  tool in this repository has ever defaulted to.
