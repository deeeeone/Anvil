cat > poly.c <<'EOT'
#if 0
"""
#endif
#include <stdio.h>
int fib(int n) { return n < 2 ? n : fib(n - 1) + fib(n - 2); }
int main(void) { printf("fib(15)=%d\n", fib(15)); return 0; }
#if 0
"""
def fib(n): return n if n < 2 else fib(n - 1) + fib(n - 2)
print("fib(15)=%d" % fib(15))
#endif
EOT
