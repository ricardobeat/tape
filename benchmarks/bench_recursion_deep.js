// Deep recursion benchmark (Fibonacci 35) — stress deeper call stacks
var N = 35;

function fib(n) {
    if (n <= 1) return n;
    return fib(n - 1) + fib(n - 2);
}

var result = fib(N);
print(result);
