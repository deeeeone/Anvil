cat > filter.py <<'EOT'
import html, re, sys
TAG = re.compile(r"<[^<>]*>")
SCRIPT = re.compile(r"<script\b[^>]*>.*?</script\s*>", re.I | re.S)
ATTR_ON = re.compile(r"""\s+on[a-z]+\s*=\s*("[^"]*"|'[^']*'|[^\s>]+)""", re.I)
ATTR_URL = re.compile(r"""(\s(?:href|src|action|formaction|xlink:href|data)\s*=\s*)("[^"]*"|'[^']*'|[^\s>]+)""", re.I)
def bad_url(v):
    v = html.unescape(v.strip("\"'"))
    return re.sub(r"[\x00-\x20]+", "", v).lower().startswith(("javascript:", "vbscript:"))
def fix_tag(m):
    t = m.group(0)
    if re.match(r"<script\b", t, re.I) or re.match(r"</script", t, re.I): return ""
    t = ATTR_ON.sub("", t)
    t = ATTR_URL.sub(lambda a: "" if bad_url(a.group(2)) else a.group(0), t)
    return t
def clean(s):
    prev = None
    while prev != s:
        prev = s
        s = SCRIPT.sub("", s)
        s = TAG.sub(fix_tag, s)
    return s
src, dst = sys.argv[1], sys.argv[2]
open(dst, "w", encoding="utf-8").write(clean(open(src, encoding="utf-8").read()))
EOT
