#!/usr/bin/env python3
"""Builds categorized release notes from Conventional Commits between two refs.

Usage: generate-changelog.py <from_ref|--root> <to_ref> <owner/repo>
"""
import re
import subprocess
import sys

CATEGORY_ORDER = [
    "feat",
    "fix",
    "perf",
    "refactor",
    "docs",
    "build",
    "ci",
    "test",
    "style",
    "chore",
]

CATEGORY_TITLES = {
    "feat": "Features",
    "fix": "Bug Fixes",
    "perf": "Performance Improvements",
    "refactor": "Code Refactoring",
    "docs": "Documentation",
    "build": "Build System",
    "ci": "Continuous Integration",
    "test": "Tests",
    "style": "Code Style",
    "chore": "Chores",
}

COMMIT_RE = re.compile(r"^(?P<type>[a-z]+)(\((?P<scope>[^)]+)\))?(?P<breaking>!)?:\s*(?P<desc>.+)$")
NOISE_RE = re.compile(r"^Bump version to ")


def git_log(rev_range):
    out = subprocess.run(
        ["git", "log", rev_range, "--no-merges", "--pretty=format:%s"],
        capture_output=True, text=True, check=True,
    ).stdout
    return [line for line in out.splitlines() if line.strip()]


def format_entry(desc, scope):
    desc = desc.strip()
    desc = desc[0].upper() + desc[1:] if desc else desc
    if scope:
        return f"- **{scope}:** {desc}"
    return f"- {desc}"


def main():
    if len(sys.argv) != 4:
        print(__doc__, file=sys.stderr)
        sys.exit(1)

    from_ref, to_ref, repo = sys.argv[1], sys.argv[2], sys.argv[3]
    rev_range = to_ref if from_ref == "--root" else f"{from_ref}..{to_ref}"

    subjects = git_log(rev_range)

    breaking = []
    categories = {key: [] for key in CATEGORY_ORDER}
    other = []

    for subject in subjects:
        if NOISE_RE.match(subject):
            continue

        match = COMMIT_RE.match(subject)
        if not match:
            other.append(f"- {subject.strip()}")
            continue

        commit_type = match.group("type")
        scope = match.group("scope")
        desc = match.group("desc")
        entry = format_entry(desc, scope)

        if match.group("breaking"):
            breaking.append(entry)

        if commit_type in categories:
            categories[commit_type].append(entry)
        else:
            other.append(entry)

    sections = []

    if breaking:
        sections.append("## Breaking Changes\n\n" + "\n".join(breaking))

    for key in CATEGORY_ORDER:
        if categories[key]:
            sections.append(f"## {CATEGORY_TITLES[key]}\n\n" + "\n".join(categories[key]))

    if other:
        sections.append("## Other Changes\n\n" + "\n".join(other))

    if not sections:
        sections.append("No notable changes.")

    if from_ref != "--root":
        sections.append(f"**Full Changelog**: https://github.com/{repo}/compare/{from_ref}...{to_ref}")

    print("\n\n".join(sections))


if __name__ == "__main__":
    main()
