#!/usr/bin/env python3
"""List vendor blob names that Make cannot express in a PRODUCT_COPY_FILES pair.

The pair is turned into a rule `$(dst): $(src)` by build/make/core/Makefile:167-177, so any
character that Make interprets structurally breaks the parse:
  #   comment           -> the entry is truncated -> "malformed COPY_FILE"
  :   the pair separator
  =   an assignment     -> the rule line becomes an assignment -> "commands commence before first target"
  % * ? [ ]  pattern/wildcard characters, which turn the rule into a pattern rule
  $ ` quotes ; & | < > {} ()  shell/function-meaningful in the recipe or in Make functions

Usage: namecheck.py <vendor-tree-dir>
"""
import os
import sys

RISKY = "#:=%*?[]{}()<>&|;$'\"`\t\n "


def main():
    root = sys.argv[1] if len(sys.argv) > 1 else "."
    hits = {}
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if d != "lost+found"]
        for name in filenames:
            rel = os.path.relpath(os.path.join(dirpath, name), root)
            bad = [c for c in RISKY if c in rel]
            if bad:
                hits.setdefault("".join(sorted(set(bad))), []).append(rel)
    if not hits:
        print("no risky names under %s" % root)
        return 0
    for chars, items in sorted(hits.items()):
        print("chars %r : %d file(s)" % (chars, len(items)))
        for rel in sorted(items)[:10]:
            print("    %s" % rel)
    return 0


if __name__ == "__main__":
    sys.exit(main())
