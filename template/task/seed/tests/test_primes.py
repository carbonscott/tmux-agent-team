import pytest
from kit.primes import is_prime, primes_upto, factorize


@pytest.mark.parametrize("n", [2, 3, 5, 97, 7919, 104729, 2147483647])
def test_prime(n):
    assert is_prime(n) is True


@pytest.mark.parametrize("n", [-7, 0, 1, 4, 91, 561, 7917, 1000001])
def test_not_prime(n):
    assert is_prime(n) is False


def test_primes_upto():
    assert primes_upto(30) == [2, 3, 5, 7, 11, 13, 17, 19, 23, 29]
    assert primes_upto(1) == []
    assert primes_upto(2) == [2]
    assert len(primes_upto(100000)) == 9592


def test_factorize():
    assert factorize(360) == [(2, 3), (3, 2), (5, 1)]
    assert factorize(97) == [(97, 1)]
    assert factorize(1) == []
    assert factorize(2 ** 10 * 3) == [(2, 10), (3, 1)]
    assert factorize(600851475143) == [(71, 1), (839, 1), (1471, 1), (6857, 1)]


def test_factorize_product():
    for n in range(2, 2000):
        prod = 1
        for p, e in factorize(n):
            assert is_prime(p) and e >= 1
            prod *= p ** e
        assert prod == n


@pytest.mark.parametrize("bad", [0, -5])
def test_factorize_rejects(bad):
    with pytest.raises(ValueError):
        factorize(bad)
