sed -i '' 's/<text_stat.h>/"textstat.h"/' src/main.c
sed -i '' 's/^CFLAGS = -Wall -O2/CFLAGS = -Wall -O2 -Iinclude/' Makefile
python3 - <<'EOT'
p='src/textstat.c'; s=open(p).read()
s=s.replace('''    for (; *s; s++) if (*s == '\\n') n++;
    return n;''','''    const char *last = s;
    for (; *s; s++) { if (*s == '\\n') n++; last = s; }
    if (last != s && *last != '\\n') n++;
    return n;''')
open(p,'w').write(s)
EOT
