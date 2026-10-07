#!/usr/bin/env bash
# Keeps Sources/Hushdeck/Resources/Localizable.xcstrings in step with the code, the
# way Xcode does: build the app target (the Swift compiler writes a .stringsdata file
# per source listing every localizable string), then `xcstringstool sync` adds new
# strings to the catalog and marks unused ones stale.
#
#   scripts/sync-strings.sh          # update the catalog in place
#   scripts/sync-strings.sh --check  # CI: fail if the catalog is out of date or
#                                    # any language is missing a translation
#
# After syncing, translate new entries (state "new" / missing languages) by editing the
# catalog in Xcode or directly in the JSON, and delete entries marked stale.
set -euo pipefail

APP_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CATALOG="$APP_ROOT/Sources/Hushdeck/Resources/Localizable.xcstrings"
SCRATCH="$APP_ROOT/.build/strings"
CHECK=0
[[ "${1:-}" == "--check" ]] && CHECK=1

cd "$APP_ROOT"
# A separate scratch path gives a clean set of .stringsdata files for exactly the
# current sources. The explicit flags make the native build system emit them too
# (Swift Build emits them on its own).
mkdir -p "$SCRATCH/stringsdata"
swift build --scratch-path "$SCRATCH" --product Hushdeck \
    -Xswiftc -emit-localized-strings -Xswiftc -emit-localized-strings-path -Xswiftc "$SCRATCH/stringsdata" >/dev/null

# Newest .stringsdata per existing source file of the app target (incremental builds
# leave older copies and files for deleted sources behind).
STRINGSDATA=()
while IFS= read -r file; do STRINGSDATA+=("$file"); done < <(python3 - "$SCRATCH" "$APP_ROOT/Sources/Hushdeck" <<'PY'
import json, os, sys
scratch, sources = sys.argv[1], os.path.realpath(sys.argv[2]) + "/"
newest = {}
for root, _, files in os.walk(scratch):
    for name in files:
        if not name.endswith(".stringsdata"): continue
        path = os.path.join(root, name)
        try: source = os.path.realpath(json.load(open(path))["source"])
        except Exception: continue
        if not source.startswith(sources) or not os.path.exists(source): continue
        if source not in newest or os.path.getmtime(path) > os.path.getmtime(newest[source]):
            newest[source] = path
print("\n".join(sorted(newest.values())))
PY
)
if [[ ${#STRINGSDATA[@]} -eq 0 ]]; then
    echo "error: the compiler produced no .stringsdata files" >&2
    exit 1
fi

if [[ $CHECK -eq 1 ]]; then
    WORK="$(mktemp -d)"
    trap 'rm -rf "$WORK"' EXIT
    cp "$CATALOG" "$WORK/Localizable.xcstrings"
    xcrun xcstringstool sync "$WORK/Localizable.xcstrings" --stringsdata "${STRINGSDATA[@]}"
    status=0
    if ! python3 - "$CATALOG" "$WORK/Localizable.xcstrings" <<'PY'
import json, sys
before = json.load(open(sys.argv[1]))["strings"]
after = json.load(open(sys.argv[2]))["strings"]
added = sorted(set(after) - set(before))
stale = sorted(k for k, v in after.items() if v.get("extractionState") == "stale")
for key in added: print(f"missing from catalog: {key!r}")
for key in stale: print(f"no longer used: {key!r}")
sys.exit(1 if added or stale else 0)
PY
    then
        echo "error: Localizable.xcstrings is out of date. Run scripts/sync-strings.sh and translate." >&2
        status=1
    fi
    python3 - "$CATALOG" <<'PY' || status=1
import json, sys
catalog = json.load(open(sys.argv[1]))
source = catalog["sourceLanguage"]
strings = {k: v for k, v in catalog["strings"].items() if v.get("shouldTranslate", True)}
languages = sorted({l for v in strings.values() for l in v.get("localizations", {})} - {source})
bad = 0
for lang in languages:
    for key, value in sorted(strings.items()):
        unit = value.get("localizations", {}).get(lang, {}).get("stringUnit")
        if not value.get("localizations", {}).get(lang, {}).get("variations") and (not unit or unit.get("state") != "translated"):
            print(f"{lang}: not translated: {key!r}"); bad += 1
print(f"languages: {', '.join([source] + languages)}; strings: {len(strings)}")
sys.exit(1 if bad else 0)
PY
    exit $status
fi

xcrun xcstringstool sync "$CATALOG" --stringsdata "${STRINGSDATA[@]}"
python3 - "$CATALOG" <<'PY'
import json, sys
catalog = json.load(open(sys.argv[1]))
strings = catalog["strings"]
stale = [k for k, v in strings.items() if v.get("extractionState") == "stale"]
langs = sorted({l for v in strings.values() for l in v.get("localizations", {})} - {catalog["sourceLanguage"]})
untranslated = {l: sum(1 for v in strings.values() if v.get("shouldTranslate", True)
                       and v.get("localizations", {}).get(l, {}).get("stringUnit", {}).get("state") != "translated"
                       and not v.get("localizations", {}).get(l, {}).get("variations")) for l in langs}
print(f"{len(strings)} strings; stale: {len(stale)}; untranslated: {untranslated}")
PY
