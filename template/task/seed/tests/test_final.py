from kit.final import run

SCRIPT = """
# a tour of the whole kit
roman 1994
unroman MMXXIV
rle aaabcc
unrle 3a1b2c
base 255 16
unbase -1010 2
factor 360
factor 97
factor 1
merge 1-3 2-6 8-10 15-18
let x = 3/4
let y = x^2 + 1
calc (x + y) * 8
calc max(x, y, 2) - 1/2

roman 0
bogus 12
calc 1/0
"""

EXPECTED = ["MCMXCIV", "2024", "3a1b2c", "aaabcc", "ff", "-10", "2^3 * 3^2 * 5", "97", "1",
            "1-6 8-10 15-18", "x = 3/4", "y = 25/16", "37/2", "3/2", "error", "error", "error"]


def test_tour():
    assert run(SCRIPT) == EXPECTED


def test_empty():
    assert run("") == []
    assert run("\n  \n# only a comment\n") == []


def test_text_arguments_keep_inner_spaces():
    assert run("rle a  b") == ["1a2 1b"]
    assert run("unrle 2 1x") == ["  x"]


def test_more_commands():
    assert run("merge 1-4 4-5\nmerge 3-1\nbase 255 99\nunbase zz 36") == ["1-5", "error", "error", "1295"]
    assert run("factor 1024\nfactor 0\nfactor x") == ["2^10", "error", "error"]
    assert run("calc 2^10\ncalc 10/4\ncalc -3") == ["1024", "5/2", "-3"]


def test_variables():
    assert run("let a = 2\nlet b = a^a^a\ncalc b - a") == ["a = 2", "b = 16", "14"]
    assert run("let 1x = 3\ncalc zz\nlet q = 1/0\ncalc q") == ["error", "error", "error", "error"]


def test_runs_are_independent():
    assert run("let a = 1") == ["a = 1"]
    assert run("calc a") == ["error"]
