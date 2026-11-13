from fractions import Fraction as F

import pytest
from kit.calc import evaluate, CalcError

VALUES = [
    ("1+2*3", 7), ("(1+2)*3", 9), ("10/4", F(5, 2)), ("2^3^2", 512), ("-2^2", -4), ("(-2)^2", 4),
    ("2^-1", F(1, 2)), ("1.5*2", 3), ("0.1+0.2", F(3, 10)), ("--3", 3), ("-(-3)", 3), ("+4-+2", 2),
    ("7-2-1", 4), ("100/10/5", 2), ("2*-3", -6), (" 12 \t* ( 3 + 4 ) ", 84), ("abs(-3)+abs(3)", 6),
    ("min(3,1,2)", 1), ("max(1, 2^3, 7/2)", 8), ("abs(min(-5, 2))*2", 10), ("1/3+1/6", F(1, 2)),
    ("(2/3)^2", F(4, 9)), ("(1/2)^-2", 4), ("0^0", 1), ("007", 7),
]


@pytest.mark.parametrize("src,val", VALUES)
def test_values(src, val):
    r = evaluate(src)
    assert isinstance(r, F)
    assert r == val


def test_env():
    assert evaluate("x*y+z_1", {"x": 3, "y": F(1, 2), "z_1": 1}) == F(5, 2)
    assert evaluate("x^2", {"x": 5}) == 25
    assert isinstance(evaluate("x", {"x": 5}), F)


@pytest.mark.parametrize("bad", ["", "   ", "1+", "*3", "(1+2", "1+2)", "1 2", "2**3", "1/0", "x", "foo(1)",
                                 "2^(1/2)", "1..2", "min()", "3 $ 4", "abs(1,2)", "0^-1", "()", "1,2"])
def test_errors(bad):
    with pytest.raises(CalcError):
        evaluate(bad)


def test_unknown_name_with_env():
    with pytest.raises(CalcError):
        evaluate("x+y", {"x": 1})


def test_calcerror_is_valueerror():
    assert issubclass(CalcError, ValueError)
