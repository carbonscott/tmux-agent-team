PAIRS = [(1000, "M"), (900, "CM"), (500, "D"), (400, "CD"), (100, "C"), (90, "XC"), (50, "L"),
         (40, "XL"), (10, "X"), (9, "IX"), (5, "V"), (4, "IV"), (1, "I")]


def to_roman(n):
    if not 1 <= n <= 3999:
        raise ValueError(n)
    out = ""
    for value, numeral in PAIRS:
        while n >= value:
            out += numeral
            n -= value
    return out


def from_roman(s):
    n, i = 0, 0
    for value, numeral in PAIRS:
        while s.startswith(numeral, i):
            n += value
            i += len(numeral)
    if not s or i != len(s) or to_roman(n) != s:
        raise ValueError(s)
    return n
