#!/usr/bin/env python3
"""doc_lint.py - lint the markdown failure modes that already bit this repo.

usage: doc_lint.py [--skip RULE ...] [FILE ...]   (default: docs/*.md agentPlan.md README.md)
Prints "file:line: rule: message" findings and exits 1 when there is any. --skip RULE drops a
rule's findings (used when a dead reference is intentional history). scripts/repo_update.sh runs
this before committing/uploading, so a finding blocks the maintenance call.

rules:
  bold-unbalanced  an odd number of '**' in one paragraph (bold that crosses a blank line is a bug)
  bold-in-cell     '**' inside a table cell that is not closed inside that same cell
  num-order        numbered items in a section must ascend by 1, no duplicates
  heading-jump     heading level must not increase by more than one (h2 -> h4)
  broken-path      a relative path written as a link or in backticks does not exist
  table-columns    a table row whose cell count differs from its header row
Fenced code blocks are skipped entirely. Paths outside the repo (NAS/work paths, build output)
and glob-ish tokens are not checked.
"""

import os
import re
import sys
import pathlib

REPO = pathlib.Path(os.getcwd())
CODE_FENCE = re.compile(r"^\s*(```|~~~)")
NUM = re.compile(r"^(\s*)(\d{1,3})([.)])\s")
LINK = re.compile(r"\[[^\]]*\]\(([^)\s]+)")
BACKTICK = re.compile(r"`([^`\n]+)`")
TABLE_ROW = re.compile(r"^\s*\|.*\|\s*$")
SKIP_TOP = {"out", "out-hu", "prebuilts", "a14-work", ".git"}
# Paths that live in the Lineage/AOSP build tree or the vendor kernel, not in this repo.
EXTERNAL_PREFIXES = ("device/rockchip/", "build/", "hardware/", "frameworks/", "packages/",
                     "vendor/", "system/", "out/", "out-hu/", "prebuilts/", "lineage/",
                     "aosp/", "hal/")


def is_table_sep(line):
    body = line.strip().strip("|")
    return bool(body) and all(re.fullmatch(r":?-+:?", c.strip()) for c in body.split("|"))


def cells(line):
    s = line.strip()
    s = s[1:] if s.startswith("|") else s
    s = s[:-1] if s.endswith("|") else s
    return [c.strip() for c in s.split("|")]


BULLET = re.compile(r"^\s*([-*+]|\d{1,3}[.)])\s")


def paragraphs(lines):
    """Yield (start_index, [lines]) for non-blank runs outside fenced code blocks. A bullet or
    numbered item starts a new run, so bold must balance inside one bullet/item, not across a list."""
    i, in_code = 0, False
    while i < len(lines):
        if CODE_FENCE.match(lines[i]):
            in_code = not in_code
            i += 1
            continue
        if in_code or not lines[i].strip():
            i += 1
            continue
        start = i
        while i < len(lines) and lines[i].strip() and not CODE_FENCE.match(lines[i]):
            if i > start and BULLET.match(lines[i]):
                break
            i += 1
        yield start, lines[start:i]


def count_bold(block_lines):
    """Count '**' occurrences outside inline code. Code spans may wrap across lines, so the
    backtick state is tracked over the whole block."""
    text = "\n".join(block_lines)
    code = False
    n = 0
    i = 0
    while i < len(text):
        if text[i] == "`":
            run = 0
            while i + run < len(text) and text[i + run] == "`":
                run += 1
            if run % 2 == 1:
                code = not code
            i += run
            continue
        if not code and text.startswith("**", i):
            n += 1
            i += 2
            continue
        i += 1
    return n


def check_bold(path, lines, findings):
    for start, block in paragraphs(lines):
        if all(TABLE_ROW.match(ln) for ln in block):
            continue  # table rows are checked cell by cell by bold-in-cell
        n = count_bold(block)
        if n % 2:
            findings.append((path, start + 1, "bold-unbalanced",
                             "%d '**' markers in this block (lines %d-%d), expected an even number"
                             % (n, start + 1, start + len(block))))


def check_bold_cells(path, lines, findings):
    for i, ln in enumerate(lines):
        if not TABLE_ROW.match(ln) or is_table_sep(ln):
            continue
        for c, cell in enumerate(cells(ln)):
            if count_bold([cell]) % 2:
                findings.append((path, i + 1, "bold-in-cell",
                                 "cell %d has a stray '**' (bold does not close inside the cell): %s"
                                 % (c + 1, cell[:60])))


def check_numbers(path, lines, findings):
    """Numbered items per heading section must read 1,2,3 ... contiguously."""
    sec = "(top of file)"
    prev = {}
    for i, ln in enumerate(lines):
        if CODE_FENCE.match(ln):
            continue
        if ln.startswith("#"):
            sec = ln.strip().lstrip("#").strip()[:70] or "(untitled heading)"
            prev = {}
            continue
        m = NUM.match(ln)
        if not m:
            continue
        indent = len(m.group(1))
        n = int(m.group(2))
        last = prev.get(indent)
        if last is not None:
            if n == last:
                findings.append((path, i + 1, "num-order",
                                 "section %r: item %d repeats the previous item" % (sec, n)))
            elif n != last + 1:
                findings.append((path, i + 1, "num-order",
                                 "section %r: item %d follows item %d, expected %d" %
                                 (sec, n, last, last + 1)))
        prev[indent] = n


def check_headings(path, lines, findings):
    prev = None
    in_fence = False
    for i, ln in enumerate(lines):
        if CODE_FENCE.match(ln):
            in_fence = not in_fence
            continue
        if in_fence or not ln.startswith("#"):
            continue
        # `# ...` inside a fenced code block is shell/comment text, not a heading.
        lvl = len(ln) - len(ln.lstrip("#"))
        if prev is not None and lvl > prev + 1:
            findings.append((path, i + 1, "heading-jump", "level %d after level %d" % (lvl, prev)))
        prev = lvl


def candidate_path(token, docpath):
    """A repo-relative path worth checking, or None if it is prose/outside the repo."""
    t = token.strip()
    if not t or t.startswith("/") or any(ch in t for ch in "*<>?${} ") or ":" in t:
        return None
    if "/" not in t:
        return None
    if t.endswith("/"):
        t = t.rstrip("/")
    if "." not in pathlib.Path(t).name and not t.endswith("/"):
        return None
    first = t.split("/")[0]
    if first in SKIP_TOP or t.startswith(EXTERNAL_PREFIXES):
        return None
    if first not in {p.name for p in REPO.iterdir()}:
        return None
    return pathlib.Path(REPO, t)


def check_paths(path, lines, findings):
    docdir = path.parent
    for i, ln in enumerate(lines):
        if CODE_FENCE.match(ln):
            continue
        tokens = LINK.findall(ln) + [m for m in BACKTICK.findall(ln) if "/" in m]
        for tok in tokens:
            if re.fullmatch(r"https?://.*", tok):
                continue
            p = candidate_path(tok, docdir)
            if p is None:
                continue
            if not p.exists() and not (docdir / tok).exists():
                findings.append((path, i + 1, "broken-path", "%s does not exist" % tok))


def check_tables(path, lines, findings):
    i = 0
    while i < len(lines):
        if CODE_FENCE.match(lines[i]):
            i += 1
            continue
        if TABLE_ROW.match(lines[i]) and not is_table_sep(lines[i]):
            header = i
            want = len(cells(lines[header]))
            j = i + 1
            while j < len(lines) and TABLE_ROW.match(lines[j]):
                if is_table_sep(lines[j]):
                    j += 1
                    continue
                got = len(cells(lines[j]))
                if got != want:
                    findings.append((path, j + 1, "table-columns", "%d cells, header row (line %d) has %d"
                                     % (got, header + 1, want)))
                j += 1
            i = j
        else:
            i += 1


def lint(path):
    lines = path.read_text(encoding="utf-8").split("\n")
    findings = []
    check_bold(path, lines, findings)
    check_bold_cells(path, lines, findings)
    check_numbers(path, lines, findings)
    check_headings(path, lines, findings)
    check_paths(path, lines, findings)
    check_tables(path, lines, findings)
    return sorted(findings, key=lambda f: (str(f[1]), f[2]))


def main():
    argv = sys.argv[1:]
    skip = set()
    args = []
    i = 0
    while i < len(argv):
        if argv[i] == "--skip":
            if i + 1 >= len(argv):
                sys.stderr.write("doc_lint: --skip needs a rule name\n")
                sys.exit(2)
            skip.add(argv[i + 1])
            i += 2
        elif argv[i] in ("-h", "--help"):
            sys.stdout.write(__doc__)
            sys.exit(0)
        else:
            args.append(argv[i])
            i += 1
    if args:
        files = [pathlib.Path(p) for p in args]
    else:
        files = sorted((REPO / "docs").glob("*.md")) + [REPO / "agentPlan.md", REPO / "README.md"]
    total = 0
    for f in files:
        if not f.exists():
            sys.stderr.write("doc_lint: %s does not exist\n" % f)
            sys.exit(2)
        for p, line, rule, msg in lint(f):
            if rule in skip:
                continue
            sys.stdout.write("%s:%d: %s: %s\n" % (p, line, rule, msg))
            total += 1
    sys.stderr.write("doc_lint: %d findings in %d files%s\n" %
                     (total, len(files), (" (skipped: %s)" % ", ".join(sorted(skip))) if skip else ""))
    sys.exit(1 if total else 0)


if __name__ == "__main__":
    main()
