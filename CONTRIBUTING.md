Hello and thank-you for considering contributing to lua-http!

If you haven't already, see the [getting started](https://github.com/daurnimator/lua-http#getting-started) section of the main readme.

# Contributing

To submit your code for inclusion, please [send a "pull request" using github](https://github.com/daurnimator/lua-http/pulls).
For a speedy approval, please:

  - Follow the [coding style](#coding-style)
  - Run [`luacheck`](https://github.com/mpeterv/luacheck) to lint your code
  - Include [tests](#tests)
	  - Bug fixes should add a test exhibiting the issue
	  - Enhancements must add tests for the new feature
  - [Sign off](#dco) your code


If you are requested by a project maintainer to fix an issue with your pull request, please edit your existing commits (using e.g. `git commit --amend` or [`git fixup`](https://github.com/hashbang/dotfiles/blob/master/git/.local/bin/git-fixup)) rather than pushing new commits on top of the old ones.

All commits *should* have the project in an operational state.


# Coding Style

When editing an existing file, please follow the coding style used in that file.
If not clear from context or if you're starting a new file:

  - Indent with tabs
  - Alignment should not be done; when unavoidable, align with spaces
  - Remove any trailing whitespace (unless whitespace is significant as it can be in e.g. markdown)
  - Things (e.g. table fields) should be ordered by:
	 1. Required vs optional
	 2. Importance
	 3. Lexographically (alphabetically)


## Lua conventions

  - Add a `__name` field to metatables
  - Use a separate table than the metatable itself for `__index`
  - Single-line table definitions should use commas (`,`) for delimiting elements
  - Multi-line table definitions should use semicolons (`;`) for delimiting elements


## Markdown conventions

  - Files should have two blank lines at the end of a section
  - Repository information files (e.g. README.md/CONTRIBUTING.md) should use github compatible markdown features
  - Files used to generate documentation can use any `pandoc` features they want


# Tests

The project has a test suite using the [`busted`](https://github.com/Olivine-Labs/busted) framework.
Coverage is measured using [`luacov`](https://github.com/keplerproject/luacov).

Tests can be found in the `spec/` directory at the root of the repository. Each source file should have its own file full of tests.

Tests should avoid running any external processes. Use `cqueues` to start up various test servers and clients in-process.

A successful test should close any file handles and sockets to avoid resource exhaustion.


# Legal

All code in the repository is covered by `LICENSE.md`.

## DCO

A git `Signed-off-by` statement in a commit message in this repository refers to the [Developer Certificate of Origin](https://developercertificate.org/) (DCO).
By signing off your commit you are making a legal statement that the work is contributed under the license of this project.
You can add the statement to your commit by passing `-s` to `git commit`


# Security

If you find a security vulnerabilities in the project and do not wish to file it publically on the [issue tracker](https://github.com/daurnimator/lua-http/issues) then you may email [lua-http-security@daurnimator.com](mailto:lua-http-security@daurnimator.com). You may encrypt your mail using PGP to the key with fingerprint [954A3772D62EF90E4B31FBC6C91A9911192C187A](https://daurnimator.com/post/109075829529/gpg-key).
