#!/usr/bin/env python3
"""tests/test_doc_edit.py - behaviour tests for tools/doc_edit.py and tools/doc_lint.py.

Run:  python3 -m unittest discover -s tests   (or: python3 tests/test_doc_edit.py)

Scratch lives under /tmp/opencode, never in the repo, and never touches the head unit or the NAS.
The point of these tests is the safety contract: an ambiguous or missing anchor must leave the file
byte-identical, --dry-run must write nothing, and the linter must catch the two failure modes that
already corrupted this repo's docs (a table row with the wrong cell count, a numbered list that
stopped ascending).
"""

import os
import subprocess
import sys
import tempfile
import unittest
import shutil

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DOC_EDIT = os.path.join(REPO, "tools", "doc_edit.py")
DOC_LINT = os.path.join(REPO, "tools", "doc_lint.py")

# The scratch root this suite writes into. /tmp/opencode is the bench default, but on this workstation
# /tmp is a 16 GB tmpfs with a per-user quota and it fills up, so the root is overridable:
#   HU_SCRATCH_ROOT=/run/media/Daan/Opslagmonster/a14-work/tmp python3 -m pytest tests/
# If the chosen root cannot hold a temporary directory, the suite falls back to the system temp dir
# rather than failing with "Disk quota exceeded" in every test.
SCRATCH_ROOT = os.environ.get("HU_SCRATCH_ROOT") or "/tmp/opencode"


def _usable_scratch_root(root):
    """A root is usable only if a file can be written inside a fresh dir there. Creating a directory
    alone succeeds on a quota-limited tmpfs, so the probe has to write bytes."""
    os.makedirs(root, exist_ok=True)
    try:
        d = tempfile.mkdtemp(prefix="scratch_probe.", dir=root)
        with open(os.path.join(d, "probe.txt"), "w", encoding="utf-8") as fh:
            fh.write("probe\n")
        fh_check = open(os.path.join(d, "probe.txt"), "r", encoding="utf-8").read()
        if fh_check != "probe\n":
            return None
    except OSError:
        return None
    shutil.rmtree(d, ignore_errors=True)
    return root


REQUESTED_ROOT = SCRATCH_ROOT
SCRATCH_ROOT = None
for _root in (REQUESTED_ROOT, tempfile.gettempdir(), os.path.join(REPO, ".scratch_tests")):
    SCRATCH_ROOT = _usable_scratch_root(_root)
    if SCRATCH_ROOT:
        break
if SCRATCH_ROOT is None:
    raise SystemExit("tests: no writable scratch root (set HU_SCRATCH_ROOT to a writable directory)")


def run_tool(tool, args, cwd=None, stdin=None):
    p = subprocess.run([sys.executable, tool] + args, cwd=cwd, capture_output=True,
                       text=True, input=stdin or "")
    return p


class DocEditTest(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp(prefix="doc_edit_tests.", dir=SCRATCH_ROOT)
        self.path = os.path.join(self.dir, "notes.md")

    def tearDown(self):
        shutil.rmtree(self.dir, ignore_errors=True)

    def write(self, text):
        with open(self.path, "w", encoding="utf-8", newline="\n") as fh:
            fh.write(text)
        return text

    def read(self):
        with open(self.path, "rb") as fh:
            return fh.read()

    def edit(self, args, expect=0):
        p = run_tool(DOC_EDIT, [self.path] + args)
        if expect is not None:
            self.assertEqual(p.returncode, expect,
                             "expected %s, got %s\nstderr: %s" % (expect, p.returncode, p.stderr))
        return p

    def test_fuzzy_dash_anchor_insert_before(self):
        """An em dash in the file must match an anchor written with a hyphen."""
        original = self.write("# Gate\n\n- Insert the gate note \u2014 Nov 17 says raw dd waits.\n")
        self.edit(["--insert-before", "- Insert the gate note",
                   "--text", "- Pre-flight: the manifest sha must match the stick.\n"])
        got = self.read().decode()
        self.assertIn("- Pre-flight: the manifest sha must match the stick.", got)
        self.assertIn("- Insert the gate note \u2014 Nov 17 says raw dd waits.", got)
        # the em dash itself is untouched - only the anchor matching is fuzzy
        self.assertIn("\u2014", original)
        self.assertIn("\u2014", got)

    def test_ambiguous_anchor_refuses_and_lists_candidate_lines(self):
        """Two matching lines must abort, and the stderr must name both line numbers."""
        body = ("line one\nfirst candidate line\nmiddle\nsecond candidate line\nlast line\n")
        self.write(body)
        p = self.edit(["--replace", "candidate line", "--text", "x\n"], expect=2)
        self.assertIn("matched 2 lines", p.stderr)
        self.assertIn("  2: first candidate line", p.stderr)
        self.assertIn("  4: second candidate line", p.stderr)
        self.assertEqual(self.read(), body.encode())

    def test_two_line_sentence_block_replace(self):
        """A sentence wrapped across two lines is one anchor, and replaces both lines."""
        self.write("# Plan\n\nBefore the write the gate checks the\nmanifest and the card digest.\nAfter that, dd.\n")
        self.edit(["--replace",
                   "Before the write the gate checks the\nmanifest and the card digest.",
                   "--text", "The gate checks the manifest only.\n"])
        got = self.read().decode()
        self.assertIn("The gate checks the manifest only.", got)
        self.assertNotIn("manifest and the card digest", got)
        self.assertIn("After that, dd.", got)

    def test_append_at_eof_preserves_trailing_newline(self):
        self.write("# Log\n\nfirst entry\n")
        self.edit(["--append", "--text", "second entry\n"])
        got = self.read().decode()
        self.assertTrue(got.endswith("second entry\n"))
        self.assertIn("first entry\nsecond entry\n", got)

    def test_dry_run_prints_diff_and_writes_nothing(self):
        body = self.write("# Log\n\nold line\n")
        p = self.edit(["--replace", "old line", "--text", "new line\n", "--dry-run"])
        self.assertEqual(self.read(), body.encode())
        self.assertIn("new line", p.stdout)
        self.assertIn("old line", p.stdout)
        # nothing left behind in the directory
        self.assertEqual(sorted(os.listdir(self.dir)), ["notes.md"])

    def test_missing_anchor_leaves_file_byte_identical(self):
        body = self.write("# Log\n\nnothing here matches\n")
        p = self.edit(["--replace", "totally absent anchor", "--text", "x\n"], expect=2)
        self.assertEqual(self.read(), body.encode())
        self.assertIn("matched 0 lines", p.stderr)
        leftovers = [f for f in os.listdir(self.dir) if f.startswith(".doc_edit")]
        self.assertEqual(leftovers, [])

    def test_delete_block_removes_only_the_named_span(self):
        self.write("# A\n\nkeep me\nstart of block\nmid line\nend of block\nkeep me too\n")
        self.edit(["--delete-block", "start of block", "--end", "end of block"])
        got = self.read().decode()
        self.assertEqual(got, "# A\n\nkeep me\nkeep me too\n")

    def test_replace_all_applies_to_every_match(self):
        self.write("alpha 933e2ecc here\nalpha 933e2ecc again\n")
        self.edit(["--replace-all", "933e2ecc", "55be70ab"], expect=None)
        got = self.read().decode()
        self.assertNotIn("933e2ecc", got)
        self.assertEqual(got.count("55be70ab"), 2)

    def test_num_append_and_renumber_keep_the_list_contiguous(self):
        self.write("## Questions\n\n1. first\n2. second\n")
        self.edit(["--num-append", "--section", "## Questions", "--text", "third question"])
        got = self.read().decode()
        self.assertIn("3. third question", got)
        # a broken list is repaired by --renumber
        self.write("## Questions\n\n1. first\n3. second\n2. third\n")
        self.edit(["--renumber", "--section", "## Questions"])
        got = self.read().decode()
        items = [ln for ln in got.split("\n") if ln[:1].isdigit()]
        self.assertEqual([ln.split(".")[0] for ln in items], ["1", "2", "3"])


class DocLintTest(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp(prefix="doc_lint_tests.", dir=SCRATCH_ROOT)

    def tearDown(self):
        shutil.rmtree(self.dir, ignore_errors=True)

    def lint(self, name, text):
        path = os.path.join(self.dir, name)
        with open(path, "w", encoding="utf-8", newline="\n") as fh:
            fh.write(text)
        return run_tool(DOC_LINT, [path], cwd=self.dir)

    def test_bad_table_row_is_flagged(self):
        p = self.lint("t.md", "| a | b |\n|---|---|\n| x | y | z |\n")
        self.assertEqual(p.returncode, 1)
        self.assertIn("table-columns", p.stdout)
        self.assertIn("t.md:3", p.stdout)

    def test_out_of_order_numbered_list_is_flagged(self):
        p = self.lint("n.md", "## Section\n\n1. first\n3. second\n3. third\n")
        self.assertEqual(p.returncode, 1)
        self.assertIn("num-order", p.stdout)
        self.assertIn("n.md:", p.stdout)

    def test_clean_file_passes(self):
        p = self.lint("c.md", "## Section\n\n| a | b |\n|---|---|\n| x | y |\n\n1. first\n2. second\n")
        self.assertEqual(p.returncode, 0, p.stdout)


if __name__ == "__main__":
    unittest.main()
