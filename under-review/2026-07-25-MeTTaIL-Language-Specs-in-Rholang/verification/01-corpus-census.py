#!/usr/bin/env python3
# ═════════════════════════════════════════════════════════════════════════
# Corpus census — native blocks in languages/src/*.rs
# ═════════════════════════════════════════════════════════════════════════
# CHECKS      the six structural figures §V.2 reports
# FIPS CLAIM  245 fold/step bodies; 42 carriers; 14 mode-less; 144 braced of
#             which 130 carry a mode; shapes 130/62/7/27/19
# RUN FROM    anywhere. With no argument it measures the PIN by exporting
#             a72b57e0:languages/src into a temp dir — never the checkout.
#             Pass a glob to measure something else.
# LAST RUN    2026-07-25 against a72b57e0
# EXPECTED    245 / 42 / 14 / 144-130 / braced 130, binary 62, unary 7,
#             method 27, other 19 / calculator 127, rhocalc 108, led_test 7
# TEETH TEST  delete the CHAR_LIT branch and add a Rust char literal containing
#             a quote to a corpus file: the string scanner desynchronises and
#             the counts move. The corpus has none today, so the branch changes
#             no figure — it is there because the docstring PROMISED to blank
#             char literals and did not, and a scanner that lies about its own
#             coverage is the failure this whole set is about.
#
#             Also: the shape classifier's ORDER is part of the rule. braced is
#             tested first, then BINARY, UNARY, METHOD. Reorder it and
#             m.iter().map(...).collect() falls from method to other, moving two
#             corpus bodies.
# ═════════════════════════════════════════════════════════════════════════

"""Structural census of native blocks in languages/src/*.rs.  §V.2.1's rule,
   executable.  Run from the mettail-rust worktree root:
       python3 census.py 'languages/src/*.rs'
"""
import re, sys, glob, collections
import os, subprocess, tempfile, shutil

def _default_corpus():
    """No argument: export the PIN into a temp dir and measure that."""
    here = os.path.dirname(os.path.abspath(__file__))
    mr = os.environ.get("METTAIL_ROOT",
                        os.path.join(here, "..", "..", "..", "..", "mettail-rust"))
    if not os.path.isdir(os.path.join(mr, ".git")):
        raise SystemExit("no mettail-rust at %s - pass a glob, or set METTAIL_ROOT" % mr)
    tmp = tempfile.mkdtemp()
    tar = subprocess.run(["git", "archive", "a72b57e0", "languages/src"],
                         cwd=mr, capture_output=True, check=True).stdout
    subprocess.run(["tar", "-x", "-C", tmp], input=tar, check=True)
    return os.path.join(tmp, "languages", "src", "*.rs"), tmp


# A Rust CHAR literal, including every escape form.  A LIFETIME ('a, 'static)
# has no closing quote and therefore never matches, which is what keeps the
# scanner from eating `&'a str`.
CHAR_LIT = re.compile(r"'(?:\\(?:x[0-9A-Fa-f]{2}|u\{[0-9A-Fa-f]{1,6}\}|.)|[^\\'])'")

def strip(src):
    """Blank out comments and string/char literals, PRESERVING offsets."""
    out = list(src); i = 0; n = len(src)
    while i < n:
        c = src[i]
        if c == '/' and src[i+1:i+2] == '/':                      # line comment
            while i < n and src[i] != '\n': out[i] = ' '; i += 1
        elif c == '/' and src[i+1:i+2] == '*':                    # block comment
            d = 0
            while i < n:
                if src[i:i+2] == '/*': d += 1; out[i] = out[i+1] = ' '; i += 2
                elif src[i:i+2] == '*/': d -= 1; out[i] = out[i+1] = ' '; i += 2
                else:
                    if src[i] != '\n': out[i] = ' '
                    i += 1
                if d == 0: break
        elif c == 'r' and re.match(r'r#*"', src[i:i+8] or ''):     # raw string
            m = re.match(r'r(#*)"', src[i:]); close = '"' + m.group(1)
            j = src.index(close, i + len(m.group(0)))
            for k in range(i, j + len(close)):
                if src[k] != '\n': out[k] = ' '
            i = j + len(close)
        elif c == "'" and CHAR_LIT.match(src[i:]):                 # char literal
            j = i + CHAR_LIT.match(src[i:]).end()
            for k in range(i, j):
                if src[k] != '\n': out[k] = ' '
            i = j
        elif c == '"':                                            # ordinary string
            j = i + 1
            while j < n and src[j] != '"':
                j += 2 if src[j] == '\\' else 1
            for k in range(i, min(j + 1, n)):
                if src[k] != '\n': out[k] = ' '
            i = j + 1
        else:
            i += 1
    return ''.join(out)

IDENT_TAIL = re.compile(r'[A-Za-z0-9_]')

def blocks(src):
    """Every native `![ … ]`: NOT `#![…]` (inner attribute), NOT `ident![…]`
       (bang macro such as `vec![]`)."""
    res = []
    for m in re.finditer(r'!\[', src):
        s = m.start()
        if s > 0 and (src[s-1] == '#' or IDENT_TAIL.match(src[s-1])):
            continue
        d = 0; i = s + 1
        while i < len(src):                                       # bracket-match
            if src[i] == '[': d += 1
            elif src[i] == ']':
                d -= 1
                if d == 0: break
            i += 1
        if i >= len(src): continue
        res.append((src[s+2:i].strip(), src[i+1:i+40]))           # body, trailer
    return res

CARRIER = re.compile(r'^\s*as\s+[A-Za-z_]')          # ![T] as Cat
MODE    = re.compile(r'^\s*(fold|step)\b')           # ![ … ] fold / step
UNARY   = re.compile(r'^\(?\s*[-!]\s*[A-Za-z_][A-Za-z0-9_]*\s*\)?$')
BINARY  = re.compile(r'^[A-Za-z_][A-Za-z0-9_]*\s*'
                     r'(\+|-|\*|/|%|==|!=|<=|>=|<|>|&&|\|\||&|\||\^)\s*'
                     r'[A-Za-z_][A-Za-z0-9_]*$')
METHOD  = re.compile(r'^[A-Za-z_][A-Za-z0-9_]*\s*\.\s*[A-Za-z_].*$')

tot = collections.Counter(); shapes = collections.Counter(); per = collections.Counter()
_tmp = None
if len(sys.argv) > 1:
    _pattern = sys.argv[1]
else:
    _pattern, _tmp = _default_corpus()

for path in sorted(glob.glob(_pattern)):
    for body, trail in blocks(strip(open(path).read())):
        braced = body.startswith('{')
        if braced: tot['braced_all'] += 1
        if CARRIER.match(trail):  tot['carrier']  += 1; continue
        if not MODE.match(trail): tot['modeless'] += 1; continue
        tot['foldstep'] += 1; per[path.split('/')[-1]] += 1
        if   braced:             tot['braced_mode'] += 1; shapes['braced'] += 1
        elif BINARY.match(body): shapes['binary'] += 1
        elif UNARY.match(body):  shapes['unary']  += 1
        elif METHOD.match(body): shapes['method'] += 1
        else:                    shapes['other']  += 1

print("fold/step bodies     :", tot['foldstep'])
print("carrier declarations :", tot['carrier'])
print("mode-less blocks     :", tot['modeless'])
print("braced, all kinds    :", tot['braced_all'], "| mode-carrying:", tot['braced_mode'])
print("shapes:", dict(shapes), "sum", sum(shapes.values()))
print("per-language:", dict(per.most_common()))

if _tmp:
    shutil.rmtree(_tmp, ignore_errors=True)
