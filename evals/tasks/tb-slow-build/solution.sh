./slow_build.sh >/dev/null
shasum -a 256 dist/app.bin | cut -d' ' -f1 > answer.txt
