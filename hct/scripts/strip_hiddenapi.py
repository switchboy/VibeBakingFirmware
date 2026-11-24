#!/usr/bin/env python3
"""Drop the hiddenapi access-flag tokens baksmali 2.5.2 emitted for A10's hidden-API classes.

Only the tokens on `.class`, `.field` and `.method` directive lines are removed; nothing else is
touched, so access flags, modifiers, signatures and default values stay exactly as they were.
Run over hctport/fwsrc so s10fw2 (the read-only source) is never modified.
"""
import os
import re
import sys

TOKENS = {
    "blacklist", "blacklist-max-o", "greylist", "greylist-max-o", "greylist-max-p",
    "greylist-max-q", "greylist-max-r", "greylist-max-t", "whitelist",
    "unsupported", "greylist-reflection", "greylist-max-o-reflection",
    "blacklist-reflection", "core-platform-api",
}

DIRECTIVE = re.compile(r"^\.(class|field|method)(\s|$)")


def strip_line(line):
    m = DIRECTIVE.match(line)
    if not m:
        return line
    parts = line.split()
    kept = [parts[0]] + [p for p in parts[1:] if p not in TOKENS]
    return " ".join(kept) + ("\n" if line.endswith("\n") else "")


def main():
    root = sys.argv[1] if len(sys.argv) > 1 else "hctport/fwsrc"
    changed = removed = 0
    for dirpath, _dirs, files in os.walk(root):
        for f in files:
            if not f.endswith(".smali"):
                continue
            p = os.path.join(dirpath, f)
            src = open(p, "r", encoding="utf-8").read()
            out = []
            n = 0
            for line in src.splitlines(True):
                new = strip_line(line)
                if new != line:
                    n += 1
                out.append(new)
            if n:
                open(p, "w", encoding="utf-8").write("".join(out))
                changed += 1
                removed += n
    print(f"{root}: {changed} files rewritten, {removed} hiddenapi tokens removed")


if __name__ == "__main__":
    main()
