#!/usr/bin/env bash
#
# Build the single-file akropolis-monitor executable (a PEP 441 zipapp).
#
#   ./tools/build_pyz.sh          -> dist/akropolis-monitor
#
# The result is one executable file carrying akropolis_monitor plus its
# pure-Python dependencies (textual, requests, PyYAML, paramiko and their
# transitive pure-Python deps). Copy it anywhere and run it; there is no
# install step.
#
# WHAT IS DELIBERATELY *NOT* BUNDLED
# ----------------------------------
# zipimport cannot load compiled extension modules out of a zip, so anything
# with a C layer must come from the system:
#
#     sudo apt install python3-cryptography python3-bcrypt python3-nacl \
#                      python3-psycopg2
#
# This is a feature, not a workaround. cryptography stays on the
# distribution's security-update track instead of being frozen inside a
# release artifact that nobody re-cuts for six months. Bundling it would also
# make this file architecture-specific; as built, it runs on any CPython
# >= 3.10.
#
# psycopg2 is the one that is genuinely optional at runtime: dashboard.py
# guards its import behind _HAS_PSYCOPG2 and simply omits the replication-slot
# panel content when it is missing. Everything else in that apt line is
# required, because paramiko will not import without it and `logs` is built
# on paramiko.
#
# psycopg2-binary needs more care than the rest. It ships its compiled module
# *inside* the package directory (psycopg2/_psycopg.cpython-*.so) AND a
# sibling psycopg2_binary.libs/ holding ~16 vendored shared objects (libpq,
# libssl, libkrb5, ...). Those vendored files are named like
#
#     libpq-f521cc7d.so.5.17
#     libssl-fe1b61af.so.3
#
# so they do NOT end in ".so" and a `-name '*.so'` sweep walks straight past
# every one of them. That is why the find below matches '*.so*' and why the
# .libs directory is also removed by name: either measure alone leaves dead
# weight (and, worse, a false impression that the strip worked).
#
# PyYAML's _yaml and MarkupSafe's _speedups are stripped for the same reason.
# Both fall back to their pure-Python implementations automatically: slower,
# irrelevant at the volume of YAML and templating this tool does.
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="$ROOT/build/pyz"
DIST="$ROOT/dist"
OUT="$DIST/akropolis-monitor"

# Deterministic timestamps so two builds of the same commit produce the same
# bytes. Falls back to the commit date, then to a fixed epoch.
SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-$(git -C "$ROOT" log -1 --format=%ct 2>/dev/null || echo 1700000000)}"

# Releases are built on this interpreter. The artifact's *contents* depend on
# it: several dependencies pull typing_extensions only below 3.11, and the
# wheels pip picks for packages with compiled variants carry the interpreter
# tag in their metadata. A build on a newer interpreter is fine to run
# locally, but will not be byte-identical to the release, and must not be
# published: it would omit typing_extensions and fail on a 3.10 host.
REFERENCE_PYTHON="3.10"

PY="${PYTHON:-python3}"
"$PY" - <<'EOF'
import sys
if sys.version_info < (3, 10):
    sys.exit(f"need Python >= 3.10 to build, have {sys.version.split()[0]}")
EOF

PY_MM="$("$PY" -c 'import sys;print("%d.%d" % sys.version_info[:2])')"
if [ "$PY_MM" != "$REFERENCE_PYTHON" ]; then
    echo "note: building with Python $PY_MM, releases use $REFERENCE_PYTHON."
    echo "      Fine for local use; will not match the release checksum."
    echo "      For an identical artifact: PYTHON=python$REFERENCE_PYTHON $0"
fi

echo "==> cleaning"
rm -rf "$BUILD" "$OUT"
mkdir -p "$BUILD" "$DIST"

echo "==> vendoring akropolis_monitor + dependencies"
"$PY" -m pip install --quiet --no-compile --target "$BUILD" "$ROOT"

echo "==> stripping compiled artifacts (see header)"
# Whole packages that exist only to back a C layer.
rm -rf "$BUILD"/cryptography "$BUILD"/cryptography-*.dist-info \
       "$BUILD"/bcrypt "$BUILD"/bcrypt-*.dist-info \
       "$BUILD"/nacl "$BUILD"/PyNaCl-*.dist-info "$BUILD"/pynacl-*.dist-info \
       "$BUILD"/cffi "$BUILD"/cffi-*.dist-info \
       "$BUILD"/pycparser "$BUILD"/pycparser-*.dist-info \
       "$BUILD"/psycopg2 "$BUILD"/psycopg2_binary-*.dist-info \
       "$BUILD"/psycopg2_binary.libs \
       "$BUILD"/_yaml \
       "$BUILD"/bin
# Anything else compiled, plus bytecode caches. Note '*.so*', not '*.so':
# vendored libs carry their soname version after the extension.
find "$BUILD" -name '*.so*' -delete
find "$BUILD" -name '__pycache__' -type d -prune -exec rm -rf {} +

# Nothing compiled may survive. A silent miss here produces an artifact that
# is architecture-specific without saying so, or that fails to import on a
# host with a different libc. Cheap to assert, expensive to discover later.
if find "$BUILD" -name '*.so*' | grep -q .; then
    echo "error: compiled objects survived the strip:" >&2
    find "$BUILD" -name '*.so*' >&2
    exit 1
fi

# The .dist-info directories stay, but pruned to what is actually read at
# runtime or owed to the licenses of what we're bundling. METADATA is not
# optional: paramiko resolves its own version through importlib.metadata at
# import time and raises PackageNotFoundError without it. The LICENSE* /
# COPYING* / NOTICE* / AUTHORS* files are not optional either: this archive
# redistributes these packages' source, paramiko among them under the LGPL,
# and the license text has to travel with the code it covers. Most wheels
# nest theirs under dist-info/licenses/ (below our maxdepth 2, so already
# untouched), but not all of them do: mdurl 0.1.2 ships a bare top-level
# LICENSE file in its dist-info, which the obvious (METADATA-and-
# entry_points.txt-only) filter silently deletes. That bug shipped in
# akropolis v1.0.1 and was caught only by inspecting the built artifact
# directly rather than assuming the filter was exhaustive.
#
# Everything else pruned is build-host residue that makes the artifact
# non-reproducible:
#   direct_url.json  absolute path of the source tree on the build machine
#   WHEEL            interpreter tag of the downloaded wheel (cp310 vs cp312)
#   RECORD           hashes of console scripts whose shebang is the build
#                    machine's interpreter path
#   INSTALLER,
#   REQUESTED        no runtime consumer
find "$BUILD" -maxdepth 2 -type f -path '*.dist-info/*' \
     ! -name 'METADATA' ! -name 'entry_points.txt' \
     ! -iname 'LICENSE*' ! -iname 'LICENCE*' \
     ! -iname 'COPYING*' ! -iname 'NOTICE*' ! -iname 'AUTHORS*' \
     -delete
find "$BUILD" -type d -path '*.dist-info/*' -empty -delete

echo "==> writing third-party license manifest"
# One file, generated from what actually got bundled rather than hand-kept in
# sync, listing every vendored dependency's declared license. The full license
# texts themselves already travel inside the archive (see above); this is the
# human-readable index of what's in there and under what terms, shipped
# alongside the binary as dist/THIRD_PARTY_LICENSES.md.
"$PY" - "$BUILD" <<'EOF' > "$DIST/THIRD_PARTY_LICENSES.md"
import pathlib, re, sys

root = pathlib.Path(sys.argv[1])


def declared_license(meta_text: str) -> str:
    m = re.search(r'^License-Expression:\s*(.+)$', meta_text, re.M)
    if m:
        return m.group(1).strip()
    m = re.search(r'^License:\s*(.+)$', meta_text, re.M)
    if m and m.group(1).strip() and m.group(1).strip().upper() != "UNKNOWN":
        return m.group(1).strip()
    m = re.search(r'^Classifier:\s*License :: OSI Approved :: (.+)$', meta_text, re.M)
    if m:
        return m.group(1).strip()
    return "unknown, see embedded license file"


rows = []
for d in sorted(root.glob("*.dist-info")):
    name, _, version = d.name[: -len(".dist-info")].rpartition("-")
    if name.lower().replace("_", "-") == "akropolis-monitor":
        continue
    meta_path = d / "METADATA"
    meta = meta_path.read_text(errors="replace") if meta_path.exists() else ""
    lic = declared_license(meta)
    lic_files = sorted(
        p.relative_to(root)
        for p in d.rglob("*")
        if p.is_file() and re.match(r"(?i)^(LICEN[CS]E|COPYING|NOTICE|AUTHORS)", p.name)
    )
    rows.append((name, version, lic, lic_files))

print("# Third-party licenses")
print()
print("akropolis-monitor (MIT) is distributed as a single-file zipapp that")
print("also carries the pure-Python packages it depends on: their source")
print("ships inside this archive, not just akropolis-monitor's own. Each")
print("package's full license text ships alongside it, under the paths")
print("listed below; this file is the index, not a substitute for those")
print("texts.")
print()
print("paramiko is LGPL-2.1: the version bundled here is unmodified,")
print("readable Python source, sitting in this same archive next to the")
print("license that covers it.")
print()
print("| Package | Version | License | License file(s) in this archive |")
print("| :--- | :--- | :--- | :--- |")
for name, version, lic, lic_files in rows:
    if lic_files:
        paths = "<br>".join(f"`{f}`" for f in lic_files)
    else:
        paths = "*(none shipped by upstream)*"
    print(f"| {name} | {version} | {lic} | {paths} |")
EOF

echo "==> writing manifest"
"$PY" - "$BUILD" <<'EOF' > "$BUILD/BUNDLE-MANIFEST.txt"
import pathlib, sys
root = pathlib.Path(sys.argv[1])
rows = []
for d in sorted(root.glob("*.dist-info")):
    name, _, version = d.name[: -len(".dist-info")].rpartition("-")
    rows.append((name, version))
print(f"Built with Python {sys.version_info.major}.{sys.version_info.minor}.")
print("The bundled set is interpreter-dependent; an artifact built on a newer")
print("interpreter may omit packages a 3.10 host needs.")
print()
print("Packages bundled inside this file:")
print()
for name, version in rows:
    print(f"  {name:<20} {version}")
print()
print("Supplied by the system, NOT bundled (apt install python3-<name>):")
print()
for name in ("cryptography", "bcrypt", "nacl", "psycopg2"):
    print(f"  {name}")
print()
print("psycopg2 is optional: without it the dashboard runs but omits the")
print("PostgreSQL replication-slot detail. The rest are required by paramiko.")
print()
print("Licenses for the bundled packages above: see THIRD_PARTY_LICENSES.md")
print("(shipped next to this binary) or <package>.dist-info/licenses/ inside")
print("this archive.")
EOF

cat > "$BUILD/__main__.py" <<'EOF'
import sys

from akropolis_monitor.cli import main

sys.exit(main())
EOF

echo "==> normalising timestamps"
find "$BUILD" -exec touch -h -d "@$SOURCE_DATE_EPOCH" {} +

echo "==> zipping"
"$PY" -m zipapp "$BUILD" \
    --python "/usr/bin/env python3" \
    --output "$OUT" \
    --compress
chmod +x "$OUT"

echo
echo "built: $OUT ($(du -h "$OUT" | cut -f1))"
"$OUT" --version
