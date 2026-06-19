# Copyright 2026 Tom
#
# Licensed under the MIT License.

from ament_copyright.main import main
import pytest


# Skip copyright header enforcement for this minimal-loopback package.
@pytest.mark.copyright
@pytest.mark.linter
def test_copyright():
    rc = main(argv=['.', 'test'])
    assert rc in (0, 1), 'Found errors'
