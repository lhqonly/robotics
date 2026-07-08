# Copyright 2026 Tom
#
# Licensed under the MIT License.

from pathlib import Path

from ament_flake8.main import main_with_errors
import pytest


@pytest.mark.flake8
@pytest.mark.linter
def test_flake8():
    pkg_root = Path(__file__).parents[1]
    rc, errors = main_with_errors(argv=[
        str(pkg_root / 'exo_cmd'),
        str(pkg_root / 'test'),
        str(pkg_root / 'setup.py'),
    ])
    assert rc == 0, \
        'Found %d code style errors / warnings:\n' % len(errors) + \
        '\n'.join(errors)
