#!/usr/bin/env python3
"""facts.py - canonical-fact registry for this repo (facts.tsv at the repo root).

facts.tsv schema (tab separated, one fact per line, header row first):
  id  kind  value  unit  measured_date  canonical_doc  canonical_anchor  mentioned_in  notes
  kind is one of: measurement | decision | sha | path | criterion
  canonical_doc = the ONE file that states this fact; every other file that repeats it is a
  duplication the consolidation plan removes. canonical_anchor is a fuzzy substring of the
  heading/line in canonical_doc. mentioned_in is computed from the docs, not hand-written.

commands:
  facts.py add --id ID --kind KIND --value V [--unit U] [--date YYYY-MM-DD] --doc DOC
               [--anchor A] [--notes N]        append a fact (refuses a duplicate id, and refuses a
               value that is not actually present in the canonical doc - nothing gets invented)
  facts.py show ID                            print a fact plus where it appears today
  facts.py grep PATTERN                       substring search over all columns
  facts.py audit                              scan the docs of record (docs/*.md, agentPlan.md, README.md;
                                            docs/consolidation.md is excluded, because a plan has to
                                            quote the values it names) and report every doc that
                                            repeats a value whose canonical_doc is a different file
  facts.py check                              fail if a sha-shaped value in docs/*.md or
                                            agentPlan.md is not registered (shas cannot drift
                                            silently). 64-hex tokens must match a registered sha
                                            exactly; 12-hex abbreviations must match the start of
                                            a registered sha or a registered abbreviation. 8/16-hex
                                            prose shorthand and UUID segments are not gated.

Matching is fuzzy the same way tools/doc_edit.py matches: dashes fold, quotes fold, '**' markers
are ignored, byte sizes match with or without thousands separators, and an sha fact is matched by
its first 8 hex characters so the docs' abbreviated spellings count as mentions.
"""

import os
import re
import sys
import pathlib
import difflib

REPO = pathlib.Path(os.getcwd())
REGISTRY = REPO / "facts.tsv"
KINDS = ("measurement", "decision", "sha", "path", "criterion")
COLUMNS = ["id", "kind", "value", "unit", "measured_date", "canonical_doc", "canonical_anchor",
           "mentioned_in", "notes"]
TRANS = {
    0x2013: "-", 0x2014: "-", 0x2011: "-", 0x2012: "-", 0x2212: "-",
    0x2018: "'", 0x2019: "'", 0x201B: "'", 0x2032: "'", 0x2033: "'",
    0x201C: '"', 0x201D: '"', 0x00A0: " ",
}
# docs of record. facts.tsv's canonical_doc points at these, and audit counts a mention in any of
# them as a duplication. docs/consolidation.md is excluded from that scan: it is a PLAN about the
# duplicates, so it must quote the values it is naming - counting it would inflate the duplicate
# total. It stays in CHECK_ALL, so a sha written in the plan is still gated by `check`.
META_DOCS = {"docs/consolidation.md"}
SCAN_FILES = [f for f in sorted((REPO / "docs").glob("*.md")) + [REPO / "agentPlan.md", REPO / "README.md"]
              if f.relative_to(REPO).as_posix() not in META_DOCS]
CHECK_ALL = sorted((REPO / "docs").glob("*.md")) + [REPO / "agentPlan.md", REPO / "README.md"]
TOKEN64 = re.compile(r"(?<![0-9a-f])\b[0-9a-f]{64}\b(?![0-9a-f])")
TOKEN12 = re.compile(r"(?<![0-9a-f-])\b[0-9a-f]{12}\b(?![0-9a-f-])")


def err(msg, code=1):
    sys.stderr.write("facts: %s\n" % msg)
    sys.exit(code)


def norm(s):
    s = s.translate(TRANS).replace("**", "")
    s = re.sub(r"\s+", " ", s).strip().lower()
    return s


def norm_num(s):
    return norm(s).replace(",", "")


def read_registry(path=REGISTRY):
    if not path.exists():
        err("no registry at %s (run facts.py add ...)" % path)
    lines = path.read_text(encoding="utf-8").rstrip("\n").split("\n")
    rows = []
    for i, ln in enumerate(lines[1:], start=2):
        if not ln.strip():
            continue
        parts = ln.split("\t")
        if len(parts) != len(COLUMNS):
            err("%s:%d has %d columns, expected %d" % (path, i, len(parts), len(COLUMNS)))
        rows.append(dict(zip(COLUMNS, parts)))
    return rows


def match_forms(row):
    """The strings that count as this fact appearing in a doc."""
    kind, value = row["kind"], row["value"]
    if kind == "sha":
        v = value.lower()
        forms = [norm(v), norm(v[:8])]
    elif kind == "measurement":
        forms = [norm_num(value)]
    else:
        forms = [norm(value)]
    return [f for f in forms if f]


def prose_blocks(text):
    """Soft-wrapped markdown paragraphs, as (first_line_number, normalised_text).

    Prose facts (decision/criterion) are often wrapped across lines, so a line-only
    search misses them; a paragraph is searched as one string and reported at its
    first line. Tables and headings are excluded - those are one-line constructs.
    """
    blocks = []
    buf = []
    start = None
    for i, ln in enumerate(text.split("\n"), start=1):
        s = ln.strip()
        if not s or s.startswith("#") or s.startswith("|"):
            if buf:
                blocks.append((start, norm(" ".join(buf))))
                buf, start = [], None
            continue
        if start is None:
            start = i
        buf.append(s)
    if buf:
        blocks.append((start, norm(" ".join(buf))))
    return blocks


def scan_docs(rows):
    """Return {id: {doc: [line numbers]}} for every registered fact."""
    texts = {}
    for f in SCAN_FILES:
        if f.exists():
            texts[f.relative_to(REPO).as_posix()] = f.read_text(encoding="utf-8")
    hits = {}
    for row in rows:
        forms = match_forms(row)
        prose = row["kind"] in ("decision", "criterion")
        found = {}
        for rel, text in texts.items():
            lines = [norm(x) for x in text.split("\n")]
            nlines = [norm_num(x) for x in text.split("\n")]
            marks = set()
            for i, (ln, ln_num) in enumerate(zip(lines, nlines), start=1):
                for form in forms:
                    if form in ln or (row["kind"] == "measurement" and form in ln_num):
                        marks.add(i)
                        break
            if prose:
                for start, block in prose_blocks(text):
                    if any(form in block for form in forms):
                        marks.add(start)
            for i in sorted(marks):
                found.setdefault(rel, []).append(i)
        hits[row["id"]] = found
    return hits


def cmd_add(argv):
    opts = {}
    i = 0
    while i < len(argv):
        if not argv[i].startswith("--"):
            err("add: unexpected argument %r" % argv[i])
        key = argv[i][2:]
        if i + 1 >= len(argv):
            err("add: --%s needs a value" % key)
        opts[key] = argv[i + 1]
        i += 2
    for req in ("id", "kind", "value", "doc"):
        if req not in opts:
            err("add: --%s is required" % req)
    kind = opts["kind"]
    if kind not in KINDS:
        err("add: kind %r must be one of %s" % (kind, ", ".join(KINDS)))
    row = {
        "id": opts["id"], "kind": kind, "value": opts["value"],
        "unit": opts.get("unit", ""), "measured_date": opts.get("date", ""),
        "canonical_doc": opts["doc"], "canonical_anchor": opts.get("anchor", ""),
        "mentioned_in": "", "notes": opts.get("notes", ""),
    }
    doc = REPO / row["canonical_doc"]
    if not doc.exists():
        err("add: canonical_doc %s does not exist" % row["canonical_doc"])
    text = doc.read_text(encoding="utf-8")
    forms = match_forms(row)
    if not any(f in norm(text) or f in norm_num(text) for f in forms):
        err("add: value %r is not present in %s - refusing to register a value the docs do not state"
            % (row["value"], row["canonical_doc"]))
    if row["canonical_anchor"]:
        if norm(row["canonical_anchor"]) not in norm(text):
            near = difflib.get_close_matches(norm(row["canonical_anchor"]),
                                             [norm(ln) for ln in text.split("\n")], n=5, cutoff=0.5)
            err("add: canonical_anchor %r not found in %s; nearby lines: %s"
                % (row["canonical_anchor"], row["canonical_doc"], "; ".join(x[:70] for x in near)))
    rows = read_registry()
    if any(r["id"] == row["id"] for r in rows):
        err("add: id %r already registered" % row["id"])
    row["mentioned_in"] = ",".join(sorted(scan_docs([row])[row["id"]]))
    line = "\t".join(row[c] for c in COLUMNS)
    with open(REGISTRY, "a", encoding="utf-8") as fh:
        fh.write(line + "\n")
    print("added %s [%s] canonical=%s mentioned_in=%s" %
          (row["id"], row["kind"], row["canonical_doc"], row["mentioned_in"]))


def cmd_show(argv):
    if len(argv) != 1:
        err("show needs one id")
    rows = read_registry()
    row = next((r for r in rows if r["id"] == argv[0]), None)
    if row is None:
        err("no fact with id %r" % argv[0])
    hits = scan_docs([row])[row["id"]]
    for c in COLUMNS:
        sys.stdout.write("%-16s %s\n" % (c, row[c]))
    sys.stdout.write("appearances    %s\n" % ", ".join(
        "%s:%s" % (d, ",".join(str(n) for n in ns[:12])) for d, ns in sorted(hits.items())))


def cmd_grep(argv):
    if len(argv) != 1:
        err("grep needs a pattern")
    p = norm(argv[0])
    rows = read_registry()
    n = 0
    for r in rows:
        if p in norm("\t".join(r[c] for c in COLUMNS)):
            sys.stdout.write("%s\t%s\t%s\t%s\t%s\n" % (r["id"], r["kind"], r["value"],
                                                       r["unit"], r["canonical_doc"]))
            n += 1
    sys.stderr.write("facts: %d rows match %r\n" % (n, argv[0]))


def cmd_audit(_argv):
    rows = read_registry()
    hits = scan_docs(rows)
    dup_total = 0
    per_file = {}
    canonical_missing = 0
    for r in rows:
        found = hits[r["id"]]
        canon = r["canonical_doc"]
        others = {d: ns for d, ns in found.items() if d != canon}
        if canon not in found:
            canonical_missing += 1
        sys.stdout.write("%s [%s] canonical=%s value=%s%s\n" %
                         (r["id"], r["kind"], canon, r["value"][:70],
                          "" if canon in found else "  (WARN: canonical doc has no literal hit)"))
        for d in sorted(found):
            if d == canon:
                continue
            sys.stdout.write("    DUP in %s (lines %s) -> canonical is %s\n" %
                             (d, ",".join(str(n) for n in found[d][:8]), canon))
            dup_total += 1
            per_file[d] = per_file.get(d, 0) + 1
        if not others:
            sys.stdout.write("    only the canonical doc carries it\n")
    sys.stdout.write("\nSUMMARY: %d facts, %d duplicated mentions, %d facts not literally in their "
                     "canonical doc\n" % (len(rows), dup_total, canonical_missing))
    for d, n in sorted(per_file.items(), key=lambda x: -x[1]):
        sys.stdout.write("  %-30s %d repeated facts\n" % (d, n))
    return 0


def cmd_check(_argv):
    rows = read_registry()
    shas = [r["value"].lower() for r in rows if r["kind"] == "sha"]
    full = {v for v in shas if len(v) == 64}
    ids_by_prefix = {}
    for r in rows:
        if r["kind"] == "sha":
            ids_by_prefix.setdefault(r["value"].lower()[:12], []).append(r["id"])
    bad = []
    seen = set()
    for f in CHECK_ALL:
        if not f.exists():
            continue
        rel = f.relative_to(REPO).as_posix()
        text = f.read_text(encoding="utf-8")
        for i, ln in enumerate(text.split("\n"), start=1):
            for m in TOKEN64.finditer(ln):
                tok = m.group()
                if tok in seen or tok in full:
                    continue
                seen.add(tok)
                owner = ids_by_prefix.get(tok[:12])
                if owner:
                    bad.append("%s:%d: sha %s drifts from registered %s (prefix %s matches, full does not)"
                               % (rel, i, tok, ", ".join(owner), tok[:12]))
                else:
                    bad.append("%s:%d: sha %s is not registered" % (rel, i, tok))
            for m in TOKEN12.finditer(ln):
                tok = m.group()
                if any(v == tok or v.startswith(tok) or tok in v for v in shas):
                    continue
                bad.append("%s:%d: 12-hex %s is not registered as a sha" % (rel, i, tok))
    problems = sorted(set(bad))
    for b in problems:
        sys.stdout.write(b + "\n")
    sys.stderr.write("facts: check %d facts against %d docs -> %s\n" %
                     (len(rows), len(CHECK_ALL),
                      "%d problems" % len(problems) if problems else "clean"))
    sys.exit(1 if problems else 0)


def main():
    argv = sys.argv[1:]
    if not argv:
        sys.stdout.write(__doc__)
        sys.exit(2)
    cmd, rest = argv[0], argv[1:]
    if cmd == "add":
        cmd_add(rest)
    elif cmd == "show":
        cmd_show(rest)
    elif cmd == "grep":
        cmd_grep(rest)
    elif cmd == "audit":
        sys.exit(cmd_audit(rest))
    elif cmd == "check":
        cmd_check(rest)
    else:
        err("unknown command %r (add|show|grep|audit|check)" % cmd)


if __name__ == "__main__":
    main()
