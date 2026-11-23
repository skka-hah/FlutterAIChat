"""Reject common machine-local paths in repository text."""

import argparse
import re
import subprocess
from pathlib import Path
from urllib.parse import unquote


PRIVATE_PATH = re.compile(
    r"(?<![a-z0-9_/])/(?:Users|home|var/home|root|private/var/folders|Volumes)/[^/\s]"
    r"|\bfile://(?:localhost)?/[^\s]"
    r"|(?<![a-z0-9_/])[a-z]:[\\/]+(?:Users|Documents and Settings)[\\/]+[^\\/\s]",
    re.IGNORECASE,
)
HUNK = re.compile(r"^@@ -\d+(?:,\d+)? \+(\d+)(?:,\d+)? @@")


def report_match(filename, line_number, line):
    if not PRIVATE_PATH.search(unquote(line)):
        return False
    print(f"{filename}:{line_number}: machine-local path; use a portable reference")
    return True


def scan_worktree():
    root = Path(subprocess.check_output(["git", "rev-parse", "--show-toplevel"], text=True).rstrip("\n"))
    paths = subprocess.check_output(
        ["git", "-C", str(root), "ls-files", "-z", "--cached", "--others", "--exclude-standard"],
    )
    failed = False
    for name in sorted(set(paths.split(b"\0")) - {b""}):
        filename = name.decode("utf-8", errors="surrogateescape")
        path = root / filename
        if path.is_symlink() or not path.is_file() or not path.resolve().is_relative_to(root):
            continue
        data = path.read_bytes()
        if b"\0" in data:
            continue
        for line_number, line in enumerate(data.decode("utf-8", errors="replace").split("\n"), 1):
            if report_match(filename, line_number, line):
                failed = True
    return int(failed)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--base", help="Compare the current commit to its merge base with this revision")
    mode.add_argument("--all", action="store_true", help="Scan tracked and non-ignored untracked files")
    args = parser.parse_args()
    if args.all:
        return scan_worktree()
    comparison = ["--cached"]
    if args.base:
        base = subprocess.check_output(
            ["git", "rev-parse", "--verify", "--end-of-options", f"{args.base}^{{commit}}"],
            text=True,
        ).strip()
        comparison = [f"{base}...HEAD"]

    patch = subprocess.check_output(
        [
            "git", "diff", "--no-color", "--no-ext-diff", "--no-textconv",
            "--find-renames", "--unified=0", "--src-prefix=a/", "--dst-prefix=b/",
            *comparison, "--",
        ],
        text=True,
        encoding="utf-8",
        errors="replace",
    )
    failed = False
    line_number = None
    filename = ""
    for line in patch.split("\n"):
        if line.startswith("diff --git "):
            line_number = None
        elif hunk := HUNK.match(line):
            line_number = int(hunk[1])
        elif line_number is None and line.startswith("+++ "):
            filename = line[4:].removeprefix("b/").removesuffix("\t")
        elif line_number is not None and line.startswith(("+", " ")):
            if line.startswith("+") and report_match(filename, line_number, line[1:]):
                failed = True
            line_number += 1
    return int(failed)


if __name__ == "__main__":
    raise SystemExit(main())
