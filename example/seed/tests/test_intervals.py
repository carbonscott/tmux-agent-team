import pytest
from kit.intervals import merge, intersect


def test_merge():
    assert merge([(1, 3), (2, 6), (8, 10), (15, 18)]) == [(1, 6), (8, 10), (15, 18)]
    assert merge([(1, 4), (4, 5)]) == [(1, 5)]
    assert merge([]) == []
    assert merge([(5, 7), (1, 2), (2, 3), (6, 6)]) == [(1, 3), (5, 7)]
    assert merge([(1, 2), (3, 4)]) == [(1, 2), (3, 4)]


def test_merge_rejects_reversed():
    with pytest.raises(ValueError):
        merge([(3, 1)])


def test_intersect():
    a = [(0, 2), (5, 10), (13, 23), (24, 25)]
    b = [(1, 5), (8, 12), (15, 24), (25, 26)]
    assert intersect(a, b) == [(1, 2), (5, 5), (8, 10), (15, 23), (24, 24), (25, 25)]
    assert intersect([], [(1, 2)]) == []
    assert intersect([(1, 10)], [(2, 3), (5, 6)]) == [(2, 3), (5, 6)]
    assert intersect([(5, 9), (1, 6)], [(0, 3), (8, 20)]) == [(1, 3), (8, 9)]
    assert intersect([(1, 2)], [(3, 4)]) == []


def test_intersect_rejects_reversed():
    with pytest.raises(ValueError):
        intersect([(1, 2)], [(9, 4)])
