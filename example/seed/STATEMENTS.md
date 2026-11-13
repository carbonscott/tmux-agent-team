# Statements

The goal is a small Python package, `kit`. There are seven statements. A statement
`<name>` is **proved** when `kit/<name>.py` is on `main` and the frozen test file
`tests/test_<name>.py` passes in the merge job. Nothing else counts.

The test files are the exact statements; this page is a summary. Tests are frozen:
a merge request that changes anything other than `kit/<name>.py` (not `kit/__init__.py`)
or `tests/lemmas/test_<name>.py` is rejected. Standard library only.

You may add extra modules (`kit/_something.py`) and your own tests for them
(`tests/lemmas/test_something.py`); lemma tests must pass too.

| Statement | Module | Depends on |
|---|---|---|
| roman | `kit/roman.py` | nothing |
| rle | `kit/rle.py` | nothing |
| base | `kit/base.py` | nothing |
| primes | `kit/primes.py` | nothing |
| intervals | `kit/intervals.py` | nothing |
| calc | `kit/calc.py` | nothing (the largest one; can be split) |
| final | `kit/final.py` | all six above (the final theorem) |

## roman
- `to_roman(n: int) -> str` for 1..3999, else `ValueError`.
- `from_roman(s: str) -> int`. Only canonical upper-case numerals are accepted
  (`"IIII"`, `"IC"`, `"iv"`, `""` raise `ValueError`).

## rle
- `encode(s: str) -> str`: run-length encoding, `"aaabcc" -> "3a1b2c"`, `"" -> ""`.
  Input containing a digit raises `ValueError`.
- `decode(t: str) -> str`: inverse. Counts may have several digits (`"12a"`).
  Malformed input (`"a"`, `"3"`, `"0a"`, `"3a2"`) raises `ValueError`.

## base
- `to_base(n: int, b: int) -> str`: digits `0-9a-z`, lower case, `-` prefix for negatives.
- `from_base(s: str, b: int) -> int`: accepts upper or lower case and one leading `-`.
- `b` outside 2..36, an empty string, or a digit not valid in the base raises `ValueError`.

## primes
- `is_prime(n: int) -> bool` (False below 2).
- `primes_upto(n: int) -> list[int]`: all primes <= n.
- `factorize(n: int) -> list[tuple[int, int]]`: `(prime, exponent)` ascending;
  `factorize(1) == []`; `n < 1` raises `ValueError`.

## intervals
Closed integer intervals as `(lo, hi)` tuples; `lo > hi` raises `ValueError`.
- `merge(xs) -> list[tuple[int, int]]`: sorted union; intervals that overlap or share an
  endpoint are joined (`(1,4),(4,5) -> (1,5)`), but `(1,2),(3,4)` stay separate.
- `intersect(xs, ys) -> list[tuple[int, int]]`: sorted intersection of the two unions.

## calc
`evaluate(expr: str, env: dict | None = None) -> fractions.Fraction`, exact arithmetic.
- Literals: integers and decimals (`12`, `1.5`). Names: `[A-Za-z_][A-Za-z0-9_]*`, looked up in `env`.
- Operators, lowest to highest: `+ -`, `* /`, unary `+ -`, `^` (right-associative; the
  exponent must be an integer; `-2^2 == -4`, `2^-1 == 1/2`). Parentheses. Whitespace is ignored.
- Functions: `abs(x)`, `min(a, ...)`, `max(a, ...)` (min/max need at least one argument).
- `CalcError` (a subclass of `ValueError`) for syntax errors, unknown names or functions,
  wrong argument counts, division by zero, and non-integer exponents.

## final
`run(script: str) -> list[str]`: a line-oriented command language. One output string per
command line. Blank lines and lines starting with `#` produce nothing. Each line is stripped,
then split at the first space into a command and its argument text. Any failure
(unknown command, bad arguments, any `ValueError`) yields the string `"error"`.

| Command | Output |
|---|---|
| `roman N` | `to_roman(N)` |
| `unroman S` | `from_roman(S)` as decimal |
| `rle TEXT` / `unrle TEXT` | `encode` / `decode` of the argument text, inner spaces kept |
| `base N B` / `unbase S B` | `to_base(N, B)` / `from_base(S, B)` as decimal |
| `factor N` | `"2^3 * 3^2 * 5"` (exponent 1 is omitted; `factor 1` gives `"1"`) |
| `merge a-b c-d ...` | merged intervals as `"1-6 8-10"` (non-negative integers) |
| `calc EXPR` | the value, as `"7"` or `"5/2"` |
| `let NAME = EXPR` | stores a variable for later `calc`/`let` lines in the same run; outputs `"NAME = value"` |

Variables do not survive between calls to `run`.
