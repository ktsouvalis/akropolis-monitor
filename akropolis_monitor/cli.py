"""akropolis-monitor: operational TUIs for an Authentik HA cluster.

    akropolis-monitor dashboard                  # uses ./config.yml
    akropolis-monitor dashboard config.site-b.yml
    akropolis-monitor logs                       # TUI, last 24h
    akropolis-monitor logs --level error --last 6
    akropolis-monitor logs --save cluster_logs   # writes cluster_logs.log

The two subcommands take their config differently, and deliberately so: the
dashboard takes a bare positional path (as monitor.py always did), while logs
takes --config (as logs_viewer.py always did). Both spellings predate this
package and both are in operators' shell history and notes; unifying them
would silently break those. See CLAUDE.md.
"""

from __future__ import annotations

import argparse
import sys

from . import __version__


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="akropolis-monitor",
        description="Operational TUIs for an Authentik HA cluster.",
    )
    parser.add_argument(
        "--version", action="version", version=f"akropolis-monitor {__version__}"
    )
    sub = parser.add_subparsers(dest="command", metavar="<command>")

    p_dash = sub.add_parser(
        "dashboard",
        help="real-time cluster health dashboard",
        description="Real-time TUI dashboard for the full Authentik HA stack.",
    )
    p_dash.add_argument(
        "config",
        nargs="?",
        default="config.yml",
        help="path to the site config file (default: config.yml)",
    )

    p_logs = sub.add_parser(
        "logs",
        help="cluster-wide log viewer over SSH",
        description="Fetch warning/error logs from every node and service over SSH.",
    )
    p_logs.add_argument(
        "--config", default="config.yml", help="path to the site config file (default: config.yml)"
    )
    p_logs.add_argument(
        "--last", type=int, default=24, metavar="HOURS",
        help="hours of logs to fetch (default: 24)",
    )
    p_logs.add_argument(
        "--save", metavar="FILE",
        help="write a plain-text report to FILE instead of showing the TUI",
    )
    # These choices duplicate logs.LOG_LEVELS rather than importing it: the
    # parser is built on every invocation, including `--help`, and importing
    # logs here would drag in textual and paramiko to do it. The duplication
    # is small and static; if a level is ever added, add it in both places.
    p_logs.add_argument(
        "--level", default="warning",
        choices=["debug", "info", "warning", "error"],
        help="minimum severity to include (default: warning)",
    )

    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)

    if not args.command:
        parser.print_help()
        return 1

    # Imported inside main() rather than at module level: both submodules pull
    # in textual and their own heavy dependency sets (paramiko for logs,
    # requests/psycopg2 for the dashboard), and `--help` / `--version` should
    # not pay for either. It also means a missing optional dependency only
    # breaks the subcommand that actually needs it.
    if args.command == "dashboard":
        from . import dashboard

        dashboard.run(args.config)
        return 0

    if args.command == "logs":
        from . import logs

        logs.run(args.config, args.last, args.save, args.level)
        return 0

    parser.error(f"unknown command: {args.command}")
    return 2


if __name__ == "__main__":
    sys.exit(main())
