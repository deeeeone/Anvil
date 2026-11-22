h=$(git fsck --no-reflogs --lost-found 2>/dev/null | awk '/dangling commit/{print $3}' | head -1)
git show "$h:.env" | sed 's/^API_TOKEN=//' > recovered.txt
