# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with
code in this repository.

## What this repo is

`akropolis-monitor`: operational tooling for a UoP/ESDA-Lab **Authentik HA
cluster** (Authentik + Patroni/PostgreSQL + etcd + HAProxy + keepalived/VIP +
nginx, 3 nodes per site). Nothing here runs *inside* the cluster; everything
connects out to it over HTTP/SSH from an operator's workstation.

Companion to [akropolis](https://github.com/ktsouvalis/akropolis), which
provisions the cluster. The two are packaged the same way on purpose: when
changing the build or release machinery here, check what akropolis does first
and stay aligned unless there is a reason not to.

Repository history: this was `ak-monitor`, then `ktsouvalis/authentik`, then
`akropolis-monitor`. Older commits use the earlier names.

## Layout

```
akropolis_monitor/          the package; the only importable code
  cli.py                    argparse dispatcher, lazy-imports the two below
  dashboard.py              the health TUI (was monitor.py)
  logs.py                   the log viewer TUI (was logs_viewer.py)
tools/build_pyz.sh          builds the single-file zipapp
.github/workflows/release.yml   tag-triggered release
```

## Running

```bash
pip install -e .

akropolis-monitor dashboard                     # uses ./config.yml
akropolis-monitor dashboard config.site-b.yml   # positional arg, NOT --config
akropolis-monitor logs --config config.yml --last 12
akropolis-monitor logs --save cluster_logs      # writes cluster_logs.log, no TUI
```

**The config-flag asymmetry is deliberate.** `dashboard` takes a bare
positional path because `monitor.py` always did; `logs` takes `--config`
because `logs_viewer.py` always did. Both are in operators' shell history and
runbooks. Do not "fix" this into consistency: it is a compatibility decision,
not an oversight.

No automated tests exist, and there is no linter or formatter config. Match
the surrounding style: light annotations, `Optional[...]` from `typing`,
f-strings, Rich markup like `[bold green]...[/]`.

## Prose conventions

No em dashes anywhere in prose, comments, or output strings. Two deliberate
exceptions, both of which will look like misses and are not:

1. The single-character `"—"` placeholder glyphs the dashboard renders for
   "no data" (unknown Patroni timeline, unset last-refresh). Those are UI, not
   prose. Leave them.
2. Anything in a file that is being deleted rather than maintained. Do not
   spend edits tidying prose on its way out.

## Config files

One YAML file per site. `config.yml`, `config_esda.yml` and friends are real,
gitignored site configs; `config.yml.example` is the tracked template. **Always
update the example when adding a config key**, not just the working files.

Key sections: `nodes:` (per-service IP/name lists: `authentik`, `patroni`,
`etcd`, `haproxy`), `ports:`, `credentials:`, `keepalived:` (VIP failover
priorities), `scheme:` (optional; nginx HTTP-vs-HTTPS), `services:` (drives the
log viewer's node x service matrix).

`*.yml` and `*.csv` are gitignored, with `config.yml.example` and the workflow
under `.github/workflows/` negated back in. Check `git add -A --dry-run` after
touching `.gitignore`.

## dashboard.py architecture

Single-module Textual app. Config is held in **module-level globals**
(`SITE_NAME`, `VIP`, `AK_NODES`, `P_PATRONI`, `OK`/`DOWN`/`WARN`/`GREY`, ...)
which start as defaults and are overwritten by `load_site(path)`. `run(path)`
calls `load_site` and then starts the app; `cli.py` calls `run`.

This is the one structural thing to understand before editing:

> **Anything evaluated at import time cannot see the config.** Class bodies
> included. `App.TITLE = SITE_NAME` and `reactive(GREY)` were both bugs for
> exactly this reason: they froze pre-config defaults. Read config globals
> from *inside* methods (`__init__`, `render_content`, `compose`), never in a
> class body.

The per-service pattern, which is what to copy when adding a panel:

1. `check_<service>_node(node) -> dict` does one blocking network call and
   always returns a dict with at least `ip`, `name`, `ok`. It never raises; it
   catches its own exceptions and returns an `ok: False` sentinel of the same
   shape.
2. `action_refresh_now` (a `@work(thread=True)` method) fans these out through
   one shared `ThreadPoolExecutor`, collects `.result()`s, then hands the batch
   to `self.call_from_thread(self._apply_updates, ...)`.
3. `_apply_updates` pushes each result into its panel's `data` reactive, then
   computes a `<service>_fail` count folded into `all_failures` for the
   top-level status dot.
4. `<Service>Panel(Static)` renders `self.data` into Rich markup via
   `render_content()`, triggered by `watch_data`.

Patroni is special: its results are awaited *before* the rest of the batch,
because `check_replication_slots` and `check_patroni_history` need the
primary's IP, which is only known once `check_patroni_node` resolves.

`_fmt_lag`, `_fmt_bytes` and `failures_to_dot` are shared helpers; reuse them
rather than duplicating threshold logic. `_UNICODE`/`_BULLET` decide whether
dots render as `●` or `*`, auto-detected from locale and overridable with
`unicode_bullets`, because some Proxmox CTs lack UTF-8 locales. `load_site`
recomputes them after reading the config.

psycopg2 is optional at runtime, guarded by `_HAS_PSYCOPG2`. Keep it that way:
the released zipapp does not bundle it, and `check_replication_slots` returning
`None` is a supported state, not an error.

A Redis + Redis Sentinel panel existed here previously and was removed when
Redis Sentinel was dropped from the stack. If the architecture changes again,
`git log -p -- monitor.py` rather than assuming the current panel set is final.

## Packaging

The release artifact is a PEP 441 zipapp: one executable carrying the package
plus its pure-Python dependencies. `tools/build_pyz.sh` builds it.

Things that are load-bearing and easy to break:

- **Nothing compiled may be bundled.** zipimport cannot load `.so` files out
  of a zip. `cryptography`, `bcrypt`, `nacl`, `cffi`, `pycparser` and
  `psycopg2` are stripped and expected from the system via apt.
- **The strip pattern is `*.so*`, not `*.so`.** `psycopg2-binary` vendors
  ~16 shared objects in `psycopg2_binary.libs/` named like
  `libpq-f521cc7d.so.5.17`. None of them end in `.so`. A `*.so` sweep misses
  every one and bundles them silently. The build script asserts afterwards
  that nothing compiled survived; do not remove that assertion.
- **`.dist-info` pruning must keep license files.** METADATA is required
  (paramiko resolves its own version through `importlib.metadata` at import
  and raises `PackageNotFoundError` without it), and LICENSE/COPYING/NOTICE/
  AUTHORS are required because the archive redistributes these packages'
  source, paramiko under the LGPL. Most wheels nest licenses under
  `dist-info/licenses/`, but not all: mdurl 0.1.2 ships a bare top-level
  `LICENSE`, which a METADATA-only filter deletes silently. That shipped in
  akropolis v1.0.1. CI now fails the release if any package in
  `THIRD_PARTY_LICENSES.md` lacks a license file or names one absent from the
  archive.
- **`THIRD_PARTY_LICENSES.md` is generated at build time**, never
  hand-maintained, so it cannot drift from what was actually bundled.
- **Python 3.10 is the reference interpreter.** The bundled set is
  interpreter-dependent (`typing_extensions` only appears below 3.11).
  Building on a newer one produces an artifact that may fail on a 3.10 host,
  and will not match the release checksum.

## Releasing

Tag-triggered, mirroring akropolis. Bump the version in **both**
`pyproject.toml` and `akropolis_monitor/__init__.py` (CI fails on mismatch),
add a `## [x.y.z]` section to `CHANGELOG.md` (CI fails if the tag has no
section, since release notes are extracted from it), commit, then:

```bash
git tag -a v1.0.0 -m "akropolis-monitor 1.0.0"
git push origin master --follow-tags
```

If the tag is pushed in the same operation that first registers the workflow
file, GitHub evaluates the event against workflows it already knows about and
the run never happens. Recover with `gh workflow run release --ref v1.0.0`,
against the tag and not a branch.

## Development workflow

Commits are authored as `Konstantinos Tsouvalis <kostas.tsou@gmail.com>` and
delivered as `git format-patch` output for `git am`. Use `git commit -F <file>`
rather than `-m "..."`: backticks in commit messages get eaten by bash command
substitution.
