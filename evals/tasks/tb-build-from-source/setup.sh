#!/bin/bash
set -e
mkdir -p src include tests
cat > include/textstat.h <<'EOT'
#ifndef TEXTSTAT_H
#define TEXTSTAT_H
int count_words(const char *s);
int count_lines(const char *s);
#endif
EOT
cat > src/textstat.c <<'EOT'
#include "textstat.h"
#include <ctype.h>
int count_words(const char *s) {
    int n = 0, in = 0;
    for (; *s; s++) {
        if (isspace((unsigned char)*s)) in = 0;
        else if (!in) { in = 1; n++; }
    }
    return n;
}
int count_lines(const char *s) {
    int n = 0;
    for (; *s; s++) if (*s == '\n') n++;
    return n;
}
EOT
cat > src/main.c <<'EOT'
#include <stdio.h>
#include <stdlib.h>
#include <text_stat.h>
int main(int argc, char **argv) {
    if (argc < 2) { fprintf(stderr, "usage: %s file\n", argv[0]); return 2; }
    FILE *f = fopen(argv[1], "rb");
    if (!f) { perror(argv[1]); return 1; }
    char buf[65536]; size_t n = fread(buf, 1, sizeof buf - 1, f); buf[n] = 0; fclose(f);
    printf("words=%d lines=%d\n", count_words(buf), count_lines(buf));
    return 0;
}
EOT
cat > Makefile <<'EOT'
CC = cc
CFLAGS = -Wall -O2
SRC = src/main.c src/textstat.c

build/wc2: $(SRC)
	mkdir -p build
	$(CC) $(CFLAGS) -o $@ $(SRC)

test: build/wc2
	./build/wc2 tests/sample.txt | diff - tests/expected.txt
	./build/wc2 tests/no_newline.txt | diff - tests/expected_no_newline.txt

clean:
	rm -rf build
.PHONY: test clean
EOT
printf 'the quick brown fox\njumps over\nthe lazy dog today\n' > tests/sample.txt
printf 'words=10 lines=3\n' > tests/expected.txt
printf 'one two\nthree' > tests/no_newline.txt
printf 'words=3 lines=2\n' > tests/expected_no_newline.txt
