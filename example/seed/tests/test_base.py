import pytest
from kit.base import to_base, from_base


def test_to_base():
    assert to_base(255, 16) == "ff"
    assert to_base(0, 2) == "0"
    assert to_base(-10, 2) == "-1010"
    assert to_base(35, 36) == "z"
    assert to_base(36, 36) == "10"


def test_from_base():
    assert from_base("FF", 16) == 255
    assert from_base("ff", 16) == 255
    assert from_base("-1010", 2) == -10
    assert from_base("z", 36) == 35
    assert from_base("0", 7) == 0


def test_roundtrip():
    for b in (2, 3, 7, 16, 36):
        for n in range(-200, 201):
            assert from_base(to_base(n, b), b) == n


@pytest.mark.parametrize("n,b", [(5, 1), (5, 37), (5, 0), (5, -2)])
def test_to_base_bad_base(n, b):
    with pytest.raises(ValueError):
        to_base(n, b)


@pytest.mark.parametrize("s,b", [("2", 2), ("", 10), ("-", 10), ("1 0", 10), ("g", 16), ("10", 1), ("10", 37), ("--1", 10)])
def test_from_base_rejects(s, b):
    with pytest.raises(ValueError):
        from_base(s, b)
