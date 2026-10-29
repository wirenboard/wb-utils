## Wiren Board command-line utils

## Tests

Unit tests for the update scripts live in `tests/` and use [bats](https://bats-core.readthedocs.io/)
(Debian package `bats`): `make test`. They run automatically during the package build
(`dh_auto_test`); `DEB_BUILD_OPTIONS=nocheck` skips them.
