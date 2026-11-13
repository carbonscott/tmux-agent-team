import pytest
from kit.rle import encode, decode


def test_encode():
    assert encode("aaabcc") == "3a1b2c"
    assert encode("") == ""
    assert encode("a" * 12 + "b") == "12a1b"
    assert encode("ab ab") == "1a1b1 1a1b"


def test_decode():
    assert decode("3a1b2c") == "aaabcc"
    assert decode("") == ""
    assert decode("12a1b") == "a" * 12 + "b"
    assert decode("1a1a") == "aa"


@pytest.mark.parametrize("s", ["", "x", "hello world", "aaaa", "z" * 21 + "yy!!", "Ünïcödé  ✓✓✓", "a\nb\n\n"])
def test_roundtrip(s):
    assert decode(encode(s)) == s


def test_encode_rejects_digits():
    with pytest.raises(ValueError):
        encode("a1")


@pytest.mark.parametrize("bad", ["a", "3", "0a", "3a2", "-1a"])
def test_decode_rejects_malformed(bad):
    with pytest.raises(ValueError):
        decode(bad)
