#!/usr/bin/env python3
"""doc_edit.py - anchor-driven editor for this repo's markdown docs.

usage: doc_edit.py <file> <mode> [options]
  modes:
    --append                        text at EOF (with --section: at the end of that section block)
    --after    ANCHOR               insert block after the matched line/block
    --insert-before ANCHOR          insert block before the matched line/block
    --replace  ANCHOR               replace the matched line; extend with --end-anchor A or --lines N
    --replace-all OLD NEW           replace every occurrence of OLD (fuzzy) in the file/section
    --delete-block ANCHOR --end A   delete from the matched line through A's line (or --lines N)
    --num-append                    append the next item of a numbered list (needs --section)
    --num-replace N                 replace the Nth item of a numbered list (needs --section)
    --renumber                      renumber a numbered list so 1,2,3 stay contiguous (needs --section)
  text:   --text STR | --text-file PATH | stdin
  anchors: --regex (anchor is a regex) | --section HEADING (scope to that heading's block)
           --expected N (required match count, default 1) | --dry-run (print diff, write nothing)

Anchor matching is FUZZY on purpose: -, en dash and em dash are equivalent; curly quotes are
equivalent to straight ones; trailing whitespace on a line is ignored; an anchor may be a substring
of a line; an anchor containing newlines matches a run of consecutive lines (so a sentence split
across two lines is one anchor).

SAFETY is the point of this tool:
  * the complete new text is built in memory BEFORE the target file is opened for writing;
  * the match count must equal --expected, otherwise exit 2 printing candidate line numbers
    (and, on no match, the closest lines) so the caller can fix the anchor without guessing chars;
  * the result is asserted non-empty and sane unless --delete-block, so a failure can never
    truncate a file;
  * write to a temp file in the same directory, fsync, then os.replace();
  * untouched bytes are copied verbatim, so existing LF endings and the trailing newline survive.
exit codes: 0 ok, 2 anchor ambiguity/no match, 3 sanity refusal, 4 usage/input error.
"""

import argparse
import difflib
import hashlib
import os
import re
import sys
import tempfile

TRANS = {
    0x2013: "-", 0x2014: "-", 0x2011: "-", 0x2012: "-", 0x2212: "-",
    0x2018: "'", 0x2019: "'", 0x201B: "'", 0x2032: "'", 0x2033: "'",
    0x201C: '"', 0x201D: '"', 0x00A0: " ",
}

NUM_RE = re.compile(r"^(\s*)(\d{1,3})([.)])(\s+|$)")


def err(msg, code):
    sys.stderr.write("doc_edit: %s\n" % msg)
    sys.exit(code)


def norm(s):
    """Fold dashes/curly quotes. translate() is 1:1, so byte offsets stay valid for --replace-all."""
    return s.translate(TRANS)


def norm_match(s):
    return norm(s.strip())


def read_lines(path):
    """Return (original bytes, lines with their endings). Splitting on \\n only keeps \\r inside the
    line content, so CRLF/LF endings survive byte-for-byte."""
    raw = open(path, "rb").read()
    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError as e:
        err("%s is not valid UTF-8 (%s)" % (path, e), 4)
    parts = text.split("\n")
    lines = [p + "\n" for p in parts[:-1]]
    if parts[-1] != "":
        lines.append(parts[-1])
    return raw, lines


def content(line):
    return line.rstrip("\n").rstrip("\r")


def heading_level(line):
    c = content(line)
    if not c.startswith("#"):
        return None
    return len(c) - len(c.lstrip("#"))


def preview_candidates(lines, cand, path, limit=12):
    for i in cand[:limit]:
        sys.stderr.write("  %d: %s\n" % (i + 1, content(lines[i])[:120]))
    if len(cand) > limit:
        sys.stderr.write("  ... %d more\n" % (len(cand) - limit))


def section_scope(lines, heading, path):
    """A heading line up to the next heading of the same or shallower level.

    --section is matched fuzzy, and a leading '#' is allowed in the argument, so both
    '--section "Open questions"' and '--section "## Open questions"' work.
    """
    want = norm_match(heading.lstrip("#"))
    hits = [i for i, ln in enumerate(lines)
            if content(ln).startswith("#") and want in norm_match(content(ln).lstrip("#"))]
    if not hits:
        pool = [norm_match(content(ln).lstrip("#")) for ln in lines if content(ln).startswith("#")]
        near = difflib.get_close_matches(want, pool, n=6, cutoff=0.5)
        cand = [i for i, ln in enumerate(lines) if content(ln).startswith("#") and norm_match(content(ln).lstrip("#")) in near]
        sys.stderr.write("doc_edit: no heading matches --section %r in %s\n  headings nearby:\n" % (heading, path))
        preview_candidates(lines, cand, path)
        sys.exit(2)
    start = hits[0]
    lvl = heading_level(lines[start])
    for j in range(start + 1, len(lines)):
        h = heading_level(lines[j])
        if h is not None and h <= lvl:
            return start, j - 1
    return start, len(lines) - 1


def find_anchor(lines, scope, anchor, is_regex, mode, path):
    """Return list of inclusive (start, end) line spans; empty list means no match."""
    lo, hi = scope
    norm_lines = [norm_match(content(ln)) for ln in lines[lo:hi + 1]]
    matches = []
    if is_regex:
        try:
            rx = re.compile(anchor)
        except re.error as e:
            err("bad regex %r (%s)" % (anchor, e), 4)
        for i, nl in enumerate(norm_lines):
            if rx.search(nl):
                matches.append((lo + i, lo + i))
        return matches
    a = norm_match(anchor)
    if not a:
        err("empty anchor for --%s" % mode, 4)
    if "\n" in a:
        parts = [norm_match(x) for x in a.split("\n")]
        if any(not p for p in parts):
            err("multi-line anchor %r has an empty line" % anchor[:60], 4)
        for i in range(len(norm_lines) - len(parts) + 1):
            if parts[0] in norm_lines[i] and all(parts[k] in norm_lines[i + k] for k in range(1, len(parts))):
                matches.append((lo + i, lo + i + len(parts) - 1))
        return matches
    for i, nl in enumerate(norm_lines):
        if a in nl:
            matches.append((lo + i, lo + i))
    return matches


def require_matches(matches, anchor, mode, path, expected, lines, scope):
    if len(matches) == expected:
        return matches
    lo, hi = scope
    sys.stderr.write("doc_edit: --%s anchor %r matched %d lines in %s (expected %d)" %
                     (mode, anchor[:80], len(matches), path, expected))
    if scope != (0, len(lines) - 1):
        sys.stderr.write(" [scope: lines %d-%d]" % (lo + 1, hi + 1))
    sys.stderr.write("\n")
    if matches:
        preview_candidates(lines, [s for s, _ in matches], path)
    else:
        want = norm_match(anchor)
        pool = [norm_match(content(ln)) for ln in lines[lo:hi + 1]]
        near = difflib.get_close_matches(want, pool, n=6, cutoff=0.4)
        cand = [lo + i for i, nl in enumerate(pool) if nl in near]
        if not cand and "\n" in want:
            first = norm_match(want.split("\n")[0])
            cand = [i for i, ln in enumerate(lines) if first in norm_match(content(ln))]
        sys.stderr.write("  closest lines:\n")
        preview_candidates(lines, cand, path)
    sys.exit(2)


def block_lines(text):
    """The inserted block as lines, each ending in \\n (LF only)."""
    text = text.replace("\r\n", "\n").strip("\n")
    return [p + "\n" for p in text.split("\n")]


def norm_block(block, left, right):
    """Never let a line without a trailing newline fuse with the block."""
    b = list(block)
    if left and not left[-1].endswith("\n") and b:
        b = ["\n"] + b
    if b and not b[-1].endswith("\n") and right:
        b = b[:-1] + [b[-1] + "\n"]
    return b


def splice(lines, s, e, block):
    """Replace lines s..e (inclusive, 0-based) with block; e < s means pure insertion at s.
    Returns (new_lines, inserted_bytes, removed_bytes)."""
    b = norm_block(block, lines[:s], lines[e + 1:])
    removed = sum(len(x) for x in lines[s:e + 1]) if e >= s else 0
    return lines[:s] + b + lines[e + 1:], sum(len(x) for x in b), removed


def item_spans(lines, lo, hi):
    """Numbered items in a scope, each span excluding trailing blank lines."""
    spans = []
    i = lo
    while i <= hi:
        if NUM_RE.match(content(lines[i])):
            j = k = i
            while k + 1 <= hi:
                c = content(lines[k + 1])
                if c.startswith("#") or NUM_RE.match(c):
                    break
                k += 1
                if c.strip():
                    j = k
            spans.append((i, j))
            i = j + 1
        else:
            i += 1
    return spans


def renumber(lines, spans):
    """Rewrite leading numbers so the items read 1,2,3,... contiguously."""
    out = list(lines)
    for n, (s, _e) in enumerate(spans, start=1):
        m = NUM_RE.match(content(out[s]))
        body = content(out[s])[len(m.group(0)):]
        tail = "\n" if out[s].endswith("\n") else ""
        out[s] = m.group(1) + "%d" % n + m.group(3) + ((" " + body) if body else "") + tail
    return out


def prefixed(block, at_line, n):
    """Give the block a 'N. ' prefix unless the caller already numbered it."""
    first = content(block[0])
    if NUM_RE.match(first):
        return block
    indent = NUM_RE.match(content(at_line)).group(1) if at_line and NUM_RE.match(content(at_line)) else ""
    return ["%s%d. %s\n" % (indent, n, first)] + block[1:]


def main():
    ap = argparse.ArgumentParser(description="safe anchor-driven markdown editor")
    ap.add_argument("file")
    ap.add_argument("--append", action="store_true")
    ap.add_argument("--after", metavar="ANCHOR")
    ap.add_argument("--insert-before", metavar="ANCHOR")
    ap.add_argument("--replace", metavar="ANCHOR")
    ap.add_argument("--replace-all", nargs=2, metavar=("OLD", "NEW"))
    ap.add_argument("--delete-block", metavar="ANCHOR")
    ap.add_argument("--end", metavar="ANCHOR")
    ap.add_argument("--end-anchor", metavar="ANCHOR")
    ap.add_argument("--lines", type=int, metavar="N")
    ap.add_argument("--num-append", action="store_true")
    ap.add_argument("--num-replace", type=int, metavar="N")
    ap.add_argument("--renumber", action="store_true")
    ap.add_argument("--text")
    ap.add_argument("--text-file")
    ap.add_argument("--section")
    ap.add_argument("--regex", action="store_true")
    ap.add_argument("--expected", type=int, default=1)
    ap.add_argument("--dry-run", action="store_true")
    a = ap.parse_args()

    modes = [m for m in ("append", "after", "insert-before", "replace", "replace-all",
                         "delete-block", "num-append", "num-replace", "renumber")
             if getattr(a, m.replace("-", "_"))]
    if len(modes) != 1:
        err("exactly one mode is required (got %d)" % len(modes), 4)
    mode = modes[0]

    text = None
    if mode not in ("replace-all", "renumber", "delete-block"):
        if a.text is not None:
            text = a.text
        elif a.text_file is not None:
            text = open(a.text_file, "r", encoding="utf-8").read()
        else:
            text = sys.stdin.read()
        if not text.strip():
            err("empty --text/--text-file for --%s" % mode, 4)

    if not os.path.exists(a.file):
        err("%s does not exist" % a.file, 4)
    original_bytes, lines = read_lines(a.file)
    original_text = original_bytes.decode("utf-8")
    trailing = original_text.endswith("\n")

    scope = (0, len(lines) - 1)
    section = None
    if a.section:
        section = section_scope(lines, a.section, a.file)
        scope = section
    if mode in ("num-append", "num-replace", "renumber") and section is None:
        err("--%s needs --section (numbered lists live inside a heading block)" % mode, 4)
    if a.lines is not None and mode not in ("replace", "delete-block"):
        err("--lines only applies to --replace/--delete-block", 4)

    block = block_lines(text) if text else []
    added = len(block)
    removed = 0
    ins_total = rem_total = 0
    line_delta = 0
    anchor_line = scope[0] + 1
    inserted = text or ""

    if mode == "replace-all":
        if a.replace_all[0] == a.replace_all[1]:
            err("--replace-all: OLD and NEW are identical", 4)
        o = norm(a.replace_all[0])
        out = list(lines)
        count = 0
        for i in range(scope[0], scope[1] + 1):
            ln = lines[i]
            tail = "\n" if ln.endswith("\n") else ""
            body = ln[:-1] if tail else ln
            nl = norm(body)
            rebuilt, pos = "", 0
            while True:
                k = nl.find(o, pos)
                if k < 0:
                    rebuilt += body[pos:]
                    break
                rebuilt += body[pos:k] + a.replace_all[1]
                count += 1
                pos = k + len(o)
            out[i] = rebuilt + tail
        if count == 0:
            sys.stderr.write("doc_edit: --replace-all found no occurrence of %r in %s" %
                             (a.replace_all[0], a.file))
            if scope != (0, len(lines) - 1):
                sys.stderr.write(" [scope: lines %d-%d]" % (scope[0] + 1, scope[1] + 1))
            sys.stderr.write("\n  closest lines:\n")
            pool = [norm_match(content(ln)) for ln in lines[scope[0]:scope[1] + 1]]
            near = difflib.get_close_matches(norm(a.replace_all[0]), pool, n=5, cutoff=0.4)
            preview_candidates(lines, [scope[0] + i for i, nl in enumerate(pool) if nl in near], a.file)
            sys.exit(2)
        if a.expected != 1 and count != a.expected:
            err("--replace-all replaced %d occurrences of %r (expected %d)" % (count, a.replace_all[0], a.expected), 2)
        new_lines = out
        result_text = "".join(new_lines)
        added = removed = count
    else:
        if mode in ("num-append", "num-replace", "renumber"):
            anchor_line = scope[0] + 1
            spans = item_spans(lines, scope[0], scope[1])
            if mode == "renumber":
                if not spans:
                    err("--renumber: the section has no numbered items", 2)
                result_text = "".join(renumber(lines, spans))
                added = removed = len(spans)
            elif mode == "num-append":
                at = spans[-1][1] + 1 if spans else scope[1] + 1
                n = int(NUM_RE.match(content(lines[spans[-1][0]])).group(2)) + 1 if spans else 1
                nb = prefixed(block, lines[spans[-1][0]] if spans else None, n)
                merged, ins_total, rem_total = splice(lines, at, at - 1, nb)
                line_delta = len(nb)
                merged = renumber(merged, item_spans(merged, scope[0], scope[1] + len(nb)))
                result_text = "".join(merged)
                added = len(nb)
            else:
                idx = a.num_replace - 1
                if idx < 0 or idx >= len(spans):
                    err("--num-replace %d: the section has %d numbered items" % (a.num_replace, len(spans)), 2)
                s, e = spans[idx]
                nb = prefixed(block, lines[s], idx + 1)
                merged, ins_total, rem_total = splice(lines, s, e, nb)
                line_delta = len(nb) - (e - s + 1)
                merged = renumber(merged, item_spans(merged, scope[0], scope[1] + len(nb) - (e - s + 1)))
                result_text = "".join(merged)
                anchor_line = s + 1
                removed = e - s + 1
                added = len(nb)
        elif mode == "append":
            at = scope[1] + 1 if section else len(lines)
            new_lines, ins_total, rem_total = splice(lines, at, at - 1, block)
            result_text = "".join(new_lines)
        else:
            anchor = getattr(a, mode.replace("-", "_"))
            matches = require_matches(find_anchor(lines, scope, anchor, a.regex, mode, a.file),
                                      anchor, mode, a.file, a.expected, lines, scope)
            end_anchor = a.end_anchor if mode == "replace" else a.end
            ops = []
            if a.lines is not None:
                for s, _e in matches:
                    e = s + a.lines - 1
                    if e > scope[1]:
                        err("--lines %d runs past the scope end (line %d)" % (a.lines, scope[1] + 1), 3)
                    ops.append((s, e))
            elif end_anchor:
                hits = find_anchor(lines, scope, end_anchor, a.regex, mode, a.file)
                if not hits:
                    sys.stderr.write("doc_edit: end anchor %r matched 0 lines in %s\n  closest lines:\n" %
                                     (end_anchor[:60], a.file))
                    pool = [norm_match(content(ln)) for ln in lines[scope[0]:scope[1] + 1]]
                    near = difflib.get_close_matches(norm_match(end_anchor), pool, n=6, cutoff=0.4)
                    preview_candidates(lines, [scope[0] + i for i, nl in enumerate(pool) if nl in near], a.file)
                    sys.exit(2)
                for s, _e in matches:
                    later = [he for _hs, he in hits if he >= s]
                    if not later:
                        err("end anchor %r has no match at or after line %d" % (end_anchor[:60], s + 1), 3)
                    ops.append((s, later[0]))
            else:
                ops = list(matches)
            ops.sort(reverse=True)
            if mode == "delete-block" and len(ops) != 1:
                err("--delete-block supports one block at a time (got %d matches)" % len(ops), 3)
            new_lines = lines
            for s, e in ops:
                if e < s:
                    err("end line %d precedes the anchor line %d" % (e + 1, s + 1), 3)
                if mode == "after":
                    new_lines, ins, rem = splice(new_lines, s + 1, s, block)
                elif mode == "insert-before":
                    new_lines, ins, rem = splice(new_lines, s, s - 1, block)
                elif mode == "replace":
                    new_lines, ins, rem = splice(new_lines, s, e, block)
                else:
                    new_lines, ins, rem = splice(new_lines, s, e, [])
                ins_total += ins
                rem_total += rem
            anchor_line = ops[-1][0] + 1
            removed = sum(e - s + 1 for s, e in ops) if mode in ("replace", "delete-block") else 0
            added = len(block) * len(ops)
            result_text = "".join(new_lines)

    # ---- sanity gate: never write anything the mode cannot have produced ----
    if not result_text.strip():
        err("refusing to write an empty file (mode=%s)" % mode, 3)
    if "\x00" in result_text:
        err("refusing to write text containing NUL bytes", 3)
    if trailing and not result_text.endswith("\n"):
        err("refusing to drop the trailing newline (mode=%s)" % mode, 3)
    if mode != "delete-block" and norm_match(inserted) not in norm_match(result_text):
        err("refusing to write: the new text is absent from the composed result", 3)
    if mode in ("replace", "delete-block") and removed == 0:
        err("refusing to write: nothing was removed", 3)
    if mode in ("num-append", "num-replace", "renumber"):
        want_lines = len(original_text.splitlines()) + line_delta
        if len(result_text.splitlines()) != want_lines:
            err("refusing to write: %d lines, but --%s produces %d" %
                (len(result_text.splitlines()), mode, want_lines), 3)
    elif mode == "replace-all":
        if len(result_text.splitlines()) != len(original_text.splitlines()):
            err("refusing to write: --replace-all must not change the line count", 3)
    elif len(result_text) != len(original_text) - rem_total + ins_total:
        err("refusing to write: byte accounting does not add up (%d != %d - %d + %d)" %
            (len(result_text), len(original_text), rem_total, ins_total), 3)
    if mode != "delete-block" and mode != "replace-all" and result_text == original_text:
        err("refusing to write: the file would be unchanged", 3)
    if mode == "replace-all" and result_text == original_text:
        err("refusing to write: --replace-all changed nothing", 3)

    if a.dry_run:
        diff = difflib.unified_diff(original_text.splitlines(), result_text.splitlines(),
                                    fromfile=a.file, tofile=a.file + " (new)", lineterm="")
        sys.stdout.write("\n".join(diff) + "\n")
        sys.stdout.write("dry-run: nothing written (%d lines -> %d)\n" %
                         (len(original_text.splitlines()), len(result_text.splitlines())))
        return

    dirname = os.path.dirname(os.path.abspath(a.file))
    fd, tmp = tempfile.mkstemp(dir=dirname, prefix=".doc_edit.", suffix=".tmp")
    try:
        with os.fdopen(fd, "wb") as fh:
            fh.write(result_text.encode("utf-8"))
            fh.flush()
            os.fsync(fh.fileno())
        os.chmod(tmp, os.stat(a.file).st_mode & 0o7777)
        os.replace(tmp, a.file)
    except BaseException:
        if os.path.exists(tmp):
            os.unlink(tmp)
        raise

    print("mode=%s file=%s anchor_line=%d added=%d removed=%d lines=%d sha256=%s" %
          (mode, a.file, anchor_line, added, removed, len(result_text.splitlines()),
           hashlib.sha256(result_text.encode("utf-8")).hexdigest()))


if __name__ == "__main__":
    main()
