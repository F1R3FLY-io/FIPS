#!/bin/sh
set -eu

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
FIPS=$(dirname "$HERE")
DOC="$FIPS/2026-06-26-Foreign-Language-Terms.md"

python3 - "$DOC" <<'PY'
import pathlib
import re
import sys

doc = pathlib.Path(sys.argv[1])
raw = doc.read_text(encoding="utf-8").splitlines()


def classify_fences(lines):
    depth = 0
    opening_length = 0
    result = []
    for line in lines:
        body = line.rstrip().lstrip("> ").rstrip()
        if body.startswith("```"):
            run_length = len(body) - len(body.lstrip("`"))
            info = body[run_length:].strip()
            if depth == 0:
                depth = 1
                opening_length = run_length
                result.append(("open", line))
            elif run_length >= opening_length and not info:
                depth = 0
                result.append(("close", line))
            else:
                result.append(("inner", line))
        else:
            result.append(("code" if depth else "prose", line))
    return result, depth


classified, fence_depth = classify_fences(raw)
prose = [line for kind, line in classified if kind == "prose"]
issues = []

if fence_depth:
    issues.append("unbalanced fenced code block")

for number, line in enumerate(prose, 1):
    without_inline_math = re.sub(r"\$`[^`]*`\$", "", line)
    without_code = re.sub(r"`[^`]*`", "", without_inline_math)
    if "$" in without_code:
        issues.append(f"line {number}: nonconforming math delimiter")
    if "$$" in line:
        issues.append(f"line {number}: dollar-delimited display math")
    if "/home/" in line or "file://" in line:
        issues.append(f"line {number}: machine-local reference")

plain_lines = [line.replace(r"\|", "") for line in raw]
kinds = [kind for kind, _ in classified]
index = 0
while index < len(plain_lines):
    if (
        kinds[index] == "prose"
        and index + 1 < len(plain_lines)
        and plain_lines[index + 1].lstrip("> ").startswith("| ---")
    ):
        expected = plain_lines[index].count("|")
        row = index + 2
        while row < len(plain_lines) and plain_lines[row].lstrip("> ").startswith("|"):
            if plain_lines[row].count("|") != expected:
                issues.append(f"line {row + 1}: misaligned Markdown table row")
            row += 1
        index = row
    else:
        index += 1

text = "\n".join(raw)
for target in re.findall(r"!\[[^]]*\]\(([^)]+)\)", text):
    path = (doc.parent / target).resolve()
    if not path.is_file():
        issues.append(f"missing figure: {target}")
    if path.suffix == ".svg" and not path.with_suffix(".puml").is_file():
        issues.append(f"missing PlantUML source for figure: {target}")

for stale in (
    "first match wins",
    "new Rholang language",
    "language fingerprint as the runtime handle",
):
    if stale in text.lower():
        issues.append(f"stale design language: {stale!r}")

if issues:
    for issue in issues:
        print(f"ERROR: {issue}", file=sys.stderr)
    raise SystemExit(1)

inline_math = sum(len(re.findall(r"\$`[^`]*`\$", line)) for line in prose)
display_math = sum(1 for line in raw if line.strip() == "```math")
figures = len(re.findall(r"!\[[^]]*\]\(([^)]+\.svg)\)", text))
print(
    f"Markdown clean: {inline_math} inline math spans, "
    f"{display_math} display blocks, {figures} sourced SVG figures"
)
PY

TMPDIR_FLT=$(mktemp -d)
trap 'rm -rf -- "$TMPDIR_FLT"' EXIT HUP INT TERM
JAVA_TOOL_OPTIONS="${JAVA_TOOL_OPTIONS:+$JAVA_TOOL_OPTIONS }-Djava.awt.headless=true"
export JAVA_TOOL_OPTIONS

for source in "$FIPS"/diagrams/*.puml; do
    plantuml -tsvg -o "$TMPDIR_FLT" "$source"
    base=$(basename "$source" .puml)
    cmp "$TMPDIR_FLT/$base.svg" "$FIPS/diagrams/$base.svg"
done

printf '%s\n' "Diagrams clean: every committed SVG matches its PlantUML source"
