#!/usr/bin/env python3
"""The user-facing changelog: one Markdown file per release in changelog/ at the repo root.

The website (/changelog), the Mac app's What's New window, the iPhone app's Settings, the Sparkle
update dialog and the GitHub release all read these files. Format (see changelog/README.md):

    ---
    version: 0.3.3
    date: 2026-11-22
    title: Your AI tools, in plain sight
    matilde: I like knowing who else is in the room.
    ---

    One short, warm paragraph.

    - A few plain bullets.

Usage:
    changelog.py check [VERSION]     validate every entry; with VERSION, also require its entry
    changelog.py html VERSION        HTML fragment for the Sparkle update dialog
    changelog.py markdown VERSION    the entry's text for the GitHub release
"""
import datetime
import html
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3] / "changelog"
VERSION = re.compile(r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)")
REQUIRED = ("version", "date", "title")
OPTIONAL = ("covers", "matilde")
# Copy rules for every user-facing string (AGENTS.md, "User-facing wording"), plus the things that
# make release notes technical: PR numbers, code, file paths.
FORBIDDEN = [
    (re.compile(r"\bby us\b", re.I), 'company voice ("by us")'),
    (re.compile(r"\bwe can(no|')t read\b", re.I), 'company voice ("we can\'t read")'),
    (re.compile(r"\bnot even us\b", re.I), 'company voice ("not even us")'),
    (re.compile(r"\bFilip\b"), "the developer's name"),
    (re.compile(r"\bMathilde\b"), 'the name is spelled "Matilde"'),
    (re.compile(r"\(#\d+\)|\bPR #?\d+|\bpull request\b", re.I), "a pull request reference"),
    (re.compile(r"`"), "code formatting"),
    (re.compile(r"\b[\w-]+\.(swift|ts|py|sh|json|yml|sqlite)\b"), "a file name"),
]


class ChangelogError(ValueError):
    pass


def entry_path(version, root=ROOT):
    return Path(root) / f"{version}.md"


def parse(path):
    """Front matter (simple `key: value` lines) and the Markdown body."""
    path = Path(path)
    text = path.read_text(encoding="utf-8")
    match = re.fullmatch(r"---\n(.*?)\n---\n(.*)", text, re.S)
    if not match:
        raise ChangelogError(f"{path.name}: must start with front matter between --- lines")
    fields = {}
    for line in match[1].splitlines():
        key, sep, value = line.partition(":")
        key, value = key.strip(), value.strip()
        if not sep or not key:
            raise ChangelogError(f"{path.name}: front matter line {line!r} is not `key: value`")
        if key not in REQUIRED + OPTIONAL:
            raise ChangelogError(f"{path.name}: unknown field {key!r}")
        if key in fields:
            raise ChangelogError(f"{path.name}: {key!r} appears twice")
        # Values stay plain one-line text, so YAML (the website) and the apps' small parser agree.
        if ": " in value or value[:1] in "\"'[{>|&*!%@#":
            raise ChangelogError(f"{path.name}: keep {key!r} plain text (no quotes, no ': ')")
        fields[key] = value
    for key in REQUIRED:
        if not fields.get(key):
            raise ChangelogError(f"{path.name}: missing {key!r}")
    if not VERSION.fullmatch(fields["version"]):
        raise ChangelogError(f"{path.name}: version must look like 0.3.3")
    if path.stem != fields["version"]:
        raise ChangelogError(f"{path.name}: file name must match version {fields['version']}")
    try:
        datetime.date.fromisoformat(fields["date"])
    except ValueError:
        raise ChangelogError(f"{path.name}: date must be YYYY-MM-DD") from None
    body = match[2].strip()
    if not body:
        raise ChangelogError(f"{path.name}: needs a short intro and a few bullets")
    for pattern, reason in FORBIDDEN:
        for value in [body, *fields.values()]:
            if pattern.search(value):
                raise ChangelogError(f"{path.name}: avoid {reason}: {pattern.search(value)[0]!r}")
    return fields, body


def entries(root=ROOT):
    """Every entry, newest first."""
    paths = [p for p in Path(root).glob("*.md") if VERSION.fullmatch(p.stem)]
    parsed = [parse(p) for p in paths]
    return sorted(parsed, key=lambda e: tuple(map(int, e[0]["version"].split("."))), reverse=True)


def require(version, root=ROOT):
    path = entry_path(version, root)
    if not path.exists():
        raise ChangelogError(
            f"No changelog entry for {version}. Add changelog/{version}.md (see changelog/README.md) before releasing."
        )
    return parse(path)


def inline_html(text):
    out = html.escape(text, quote=False)
    out = re.sub(r"\[([^\]]+)\]\((https?://[^)\s]+)\)", lambda m: f'<a href="{html.escape(m[2])}">{m[1]}</a>', out)
    out = re.sub(r"\*\*(.+?)\*\*", r"<strong>\1</strong>", out)
    out = re.sub(r"(?<![\w*])\*(?!\s)(.+?)(?<!\s)\*(?![\w*])", r"<em>\1</em>", out)
    return out


def blocks(body):
    """Paragraphs and bullet lists: ("p", text) and ("ul", [items]). A line starting with "- " is
    a bullet; any other line continues the bullet or paragraph above it; a blank line ends both."""
    result = []
    for chunk in re.split(r"\n\s*\n", body.strip()):
        for line in (line.strip() for line in chunk.splitlines()):
            if not line:
                continue
            if line.startswith("- "):
                if not result or result[-1][0] != "ul" or result[-1][2]:
                    result.append(["ul", [], False])
                result[-1][1].append(line[2:].strip())
            elif result and not result[-1][2]:
                if result[-1][0] == "ul":
                    result[-1][1][-1] += " " + line
                else:
                    result[-1][1] += " " + line
            else:
                result.append(["p", line, False])
        if result:
            result[-1][2] = True  # closed by the blank line
    return [(kind, value) for kind, value, _ in result]


def to_html(fields, body):
    """A fragment (no DOCTYPE or body), which generate_appcast embeds in the feed."""
    parts = [f"<h2>{inline_html(fields['title'])}</h2>"]
    for kind, value in blocks(body):
        if kind == "p":
            parts.append(f"<p>{inline_html(value)}</p>")
        else:
            parts.append("<ul>" + "".join(f"<li>{inline_html(item)}</li>" for item in value) + "</ul>")
    parts.append('<p><a href="https://matilde.page/changelog">Everything that\'s new in Matilde</a></p>')
    return "\n".join(parts) + "\n"


def to_markdown(fields, body):
    return f"## {fields['title']}\n\n{body}\n"


def main(argv):
    if not argv or argv[0] not in ("check", "html", "markdown"):
        print(__doc__, file=sys.stderr)
        return 2
    command, rest = argv[0], argv[1:]
    try:
        if command == "check":
            found = entries()
            if rest:
                require(rest[0])
            print(f"Changelog: {len(found)} entries" + (f", including {rest[0]}" if rest else ""))
        elif command == "html":
            sys.stdout.write(to_html(*require(rest[0])))
        else:
            sys.stdout.write(to_markdown(*require(rest[0])))
    except ChangelogError as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
