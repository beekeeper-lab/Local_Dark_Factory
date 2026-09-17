#!/usr/bin/env python3
"""render-doc.py — render one of the line's Markdown documents into its HTML template.

Why a renderer lives in this repo instead of `pip install markdown`:

§06 records an artifact hash for every document the line commits, and the PR body
links the rendered HTML the judge audited. A renderer whose output moves when a
library is upgraded changes those hashes for no reason anyone can point at, and
"the document changed" stops meaning "someone changed the document". So the
subset of Markdown the document standard actually uses (§07) is implemented here,
pinned by this file, and the output is byte-stable for a given input.

It is a subset on purpose. The developer model writes structured Markdown with
required sections — a content problem, which is the one we want it solving. Raw
HTML from a 27B would be a lint problem, which is the one we do not.

usage:
  render-doc.py <markdown> <template.html> <output.html> [--title T] [--meta k=v ...]
"""
from __future__ import annotations

import argparse
import html
import re
import sys
from pathlib import Path

# ---------------------------------------------------------------- inline ----

_INLINE_CODE = re.compile(r"`([^`]+)`")
_BOLD = re.compile(r"\*\*([^*]+)\*\*")
_ITALIC = re.compile(r"(?<![*\w])\*([^*\n]+)\*(?!\*)")
_LINK = re.compile(r"\[([^\]]+)\]\(([^)\s]+)\)")


def inline(text: str) -> str:
    """Escape first, then re-introduce only the markup we chose to support."""
    out = html.escape(text, quote=False)
    # Code spans win: nothing inside them is markup.
    placeholders: list[str] = []

    def stash_code(m: re.Match[str]) -> str:
        placeholders.append(f"<code>{m.group(1)}</code>")
        return f"\x00{len(placeholders) - 1}\x00"

    out = _INLINE_CODE.sub(stash_code, out)
    out = _BOLD.sub(r"<strong>\1</strong>", out)
    out = _ITALIC.sub(r"<em>\1</em>", out)
    out = _LINK.sub(r'<a href="\2">\1</a>', out)
    for i, rep in enumerate(placeholders):
        out = out.replace(f"\x00{i}\x00", rep)
    return out


# ----------------------------------------------------------------- block ----


def render_markdown(md: str) -> tuple[str, list[tuple[int, str, str]]]:
    """Return (html body, [(level, id, text)] for every heading)."""
    lines = md.replace("\r\n", "\n").split("\n")
    out: list[str] = []
    headings: list[tuple[int, str, str]] = []
    i = 0
    list_stack: list[str] = []
    seen_ids: dict[str, int] = {}

    def close_lists() -> None:
        while list_stack:
            out.append(f"</{list_stack.pop()}>")

    def slug(text: str) -> str:
        base = re.sub(r"[^a-z0-9]+", "-", text.lower()).strip("-") or "section"
        if base in seen_ids:
            seen_ids[base] += 1
            return f"{base}-{seen_ids[base]}"
        seen_ids[base] = 0
        return base

    while i < len(lines):
        line = lines[i]

        # Fenced code. The info string becomes a label, because §07 asks for
        # every code block in a spec to say which file it is showing.
        fence = re.match(r"^```(.*)$", line)
        if fence:
            close_lists()
            info = fence.group(1).strip()
            i += 1
            body: list[str] = []
            while i < len(lines) and not lines[i].startswith("```"):
                body.append(lines[i])
                i += 1
            i += 1
            lang = info.split()[0] if info else ""
            label = info[len(lang):].strip() if info else ""
            if label:
                out.append(f'<figure class="code"><figcaption>{inline(label)}</figcaption>')
            else:
                out.append('<figure class="code">')
            cls = f' class="language-{html.escape(lang)}"' if lang else ""
            out.append(f"<pre><code{cls}>" + html.escape("\n".join(body)) + "</code></pre></figure>")
            continue

        heading = re.match(r"^(#{1,6})\s+(.*)$", line)
        if heading:
            close_lists()
            level = len(heading.group(1))
            text = heading.group(2).strip()
            hid = slug(re.sub(r"[`*]", "", text))
            headings.append((level, hid, re.sub(r"[`*]", "", text)))
            out.append(f'<h{level} id="{hid}">{inline(text)}</h{level}>')
            i += 1
            continue

        # Tables: header row, separator, body. §07's Verification section is one.
        if "|" in line and i + 1 < len(lines) and re.match(r"^\s*\|?[\s:|-]+\|[\s:|-]*$", lines[i + 1]):
            close_lists()
            def cells(row: str) -> list[str]:
                row = row.strip()
                row = row[1:] if row.startswith("|") else row
                row = row[:-1] if row.endswith("|") else row
                return [c.strip() for c in row.split("|")]

            head = cells(line)
            i += 2
            out.append(
                "<table><thead><tr>"
                + "".join(f"<th>{inline(c)}</th>" for c in head)
                + "</tr></thead><tbody>"
            )
            while i < len(lines) and "|" in lines[i] and lines[i].strip():
                out.append("<tr>" + "".join(f"<td>{inline(c)}</td>" for c in cells(lines[i])) + "</tr>")
                i += 1
            out.append("</tbody></table>")
            continue

        bullet = re.match(r"^(\s*)([-*+]|\d+\.)\s+(.*)$", line)
        if bullet:
            indent = len(bullet.group(1))
            ordered = bullet.group(2)[0].isdigit()
            tag = "ol" if ordered else "ul"
            depth = indent // 2 + 1
            while len(list_stack) > depth:
                out.append(f"</{list_stack.pop()}>")
            while len(list_stack) < depth:
                out.append(f"<{tag}>")
                list_stack.append(tag)
            out.append(f"<li>{inline(bullet.group(3))}</li>")
            i += 1
            continue

        if re.match(r"^\s*>\s?", line):
            close_lists()
            quote: list[str] = []
            while i < len(lines) and re.match(r"^\s*>\s?", lines[i]):
                quote.append(re.sub(r"^\s*>\s?", "", lines[i]))
                i += 1
            out.append(f"<blockquote>{inline(' '.join(quote).strip())}</blockquote>")
            continue

        if re.match(r"^\s*(---+|\*\*\*+)\s*$", line):
            close_lists()
            out.append("<hr>")
            i += 1
            continue

        if not line.strip():
            close_lists()
            i += 1
            continue

        # Paragraph: consume until a blank line or the start of another block.
        para: list[str] = []
        while i < len(lines) and lines[i].strip() and not re.match(
            r"^(#{1,6}\s|```|\s*([-*+]|\d+\.)\s|\s*>|\s*(---+|\*\*\*+)\s*$)", lines[i]
        ):
            para.append(lines[i].strip())
            i += 1
        if para:
            close_lists()
            out.append(f"<p>{inline(' '.join(para))}</p>")

    close_lists()
    return "\n".join(out), headings


def build_toc(headings: list[tuple[int, str, str]]) -> str:
    items = [
        f'<li class="lvl{level}"><a href="#{hid}">{html.escape(text)}</a></li>'
        for level, hid, text in headings
        if 2 <= level <= 3
    ]
    return "<ul>" + "".join(items) + "</ul>" if items else ""


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("markdown")
    ap.add_argument("template")
    ap.add_argument("output")
    ap.add_argument("--title", default=None)
    ap.add_argument("--meta", action="append", default=[],
                    help="key=value pairs rendered into the header block")
    args = ap.parse_args()

    md = Path(args.markdown).read_text()
    template = Path(args.template).read_text()

    body, headings = render_markdown(md)
    title = args.title
    if not title:
        for level, _hid, text in headings:
            if level == 1:
                title = text
                break
    title = title or Path(args.markdown).stem

    meta_rows = []
    for pair in args.meta:
        key, _, value = pair.partition("=")
        meta_rows.append(
            f'<div class="meta-row"><dt>{html.escape(key)}</dt>'
            f"<dd>{html.escape(value)}</dd></div>"
        )

    rendered = (
        template.replace("{{TITLE}}", html.escape(title))
        .replace("{{META}}", "".join(meta_rows))
        .replace("{{TOC}}", build_toc(headings))
        .replace("{{BODY}}", body)
    )
    if "{{" in rendered and re.search(r"\{\{[A-Z_]+\}\}", rendered):
        leftover = set(re.findall(r"\{\{[A-Z_]+\}\}", rendered))
        print(f"render-doc: template has unfilled placeholders: {sorted(leftover)}",
              file=sys.stderr)
        return 1

    Path(args.output).write_text(rendered)
    print(args.output)
    return 0


if __name__ == "__main__":
    sys.exit(main())
