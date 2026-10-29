# Changelog

This file records all notable changes to this project.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.0] - 2026-10-29

### Added

- `check`, `run` and `replay` to run properties from `core:testing`, with deterministic seeding that defaults to the test runner's seed.
- Integrated shrinking on the recorded choice sequence, which reports the minimal counterexample, its seed and a flag for flaky properties.
- Generators for booleans, integers of every width, floats, runes, and ASCII, UTF-8 and custom-alphabet strings.
- `arbitrary`, which builds structs, unions, enums, bit sets, arrays and slices of plain data by reflection.
- Combinators `slice_of`, `element_of`, `one_of`, `frequency`, `mapped`, `filtered`, `maybe_of` and `draw`.
- `assume` to discard cases and `note` to annotate counterexamples.
- `Config_Error` and `Generator_Error` values for malformed configuration and generator arguments, so the library never panics on bad input.

[Unreleased]: https://github.com/alexisbcz/odin-quickcheck/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/alexisbcz/odin-quickcheck/releases/tag/v0.1.0
