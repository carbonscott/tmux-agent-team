import pytest
from kit.roman import to_roman, from_roman

CASES = [(1, "I"), (4, "IV"), (9, "IX"), (14, "XIV"), (40, "XL"), (90, "XC"), (400, "CD"),
         (1994, "MCMXCIV"), (2024, "MMXXIV"), (3999, "MMMCMXCIX")]


@pytest.mark.parametrize("n,s", CASES)
def test_pairs(n, s):
    assert to_roman(n) == s
    assert from_roman(s) == n


def test_roundtrip():
    assert all(from_roman(to_roman(n)) == n for n in range(1, 4000))


@pytest.mark.parametrize("bad", [0, -1, 4000])
def test_out_of_range(bad):
    with pytest.raises(ValueError):
        to_roman(bad)


@pytest.mark.parametrize("bad", ["", "IIII", "IC", "VX", "MMMM", "abc", "iv", "XIIX"])
def test_invalid_numeral(bad):
    with pytest.raises(ValueError):
        from_roman(bad)
