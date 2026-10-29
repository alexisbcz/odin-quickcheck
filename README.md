# quickcheck

[![CI](https://github.com/alexisbcz/odin-quickcheck/actions/workflows/ci.yml/badge.svg)](https://github.com/alexisbcz/odin-quickcheck/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Odin](https://img.shields.io/badge/Odin-dev--2026--09-1e5a99.svg)](https://odin-lang.org)

Property-based testing for `core:testing`: describe what must hold for every input, and quickcheck searches for an input that breaks it, then shrinks that input to a minimal counterexample.

## Install

The repository root is the package, so you can vendor it in two ways.

As a Git submodule inside your project:

```sh
git submodule add https://github.com/alexisbcz/odin-quickcheck libs/quickcheck
```

```odin
import qc "libs/quickcheck"
```

As a copy in a shared collection that all your projects use:

```sh
git clone https://github.com/alexisbcz/odin-quickcheck ~/odin-shared/quickcheck
odin test tests -collection:shared=$HOME/odin-shared
```

```odin
import qc "shared:quickcheck"
```

## Quick start

A property is a procedure that draws inputs from a `Source` and returns `true` when the code under test behaves. `check` runs it 100 times and fails the test with a minimal counterexample when it finds a bad input.

```odin
package mylib_tests

import qc "shared:quickcheck"
import "core:slice"
import "core:testing"

gen_score :: proc(s: ^qc.Source) -> int {
	return qc.int_range(s, -1000, 1000)
}

@(test)
test_sort_orders_and_keeps_length :: proc(t: ^testing.T) {
	qc.check(t, proc(s: ^qc.Source) -> bool {
		scores := qc.slice_of(s, gen_score, 0, 50)
		sorted := slice.clone(scores)
		slice.sort(sorted)
		return len(sorted) == len(scores) && slice.is_sorted(sorted)
	})
}
```

When a property fails, the test log names the seed and lists each value the minimal failing case drew. For the run-length encoder in `examples/basic`, checked with test seed 1730212345, it reads:

```text
quickcheck: property failed after 22 case(s) and 6 shrink(s), seed 1730212345
draw 1: "aaaaaaaaaa"
encoded as 10a
```

## Generators

Every generator takes the `Source` first and shrinks toward the simplest value in its range.

| Declaration | Draws | Shrinks toward |
| --- | --- | --- |
| `boolean(s)` | `true` or `false` | `false` |
| `int_range(s, lo, hi)` | an `int` in `[lo, hi]` | the value closest to 0 |
| `integer_range(s, lo, hi)` | any integer type up to 64 bits | the value closest to 0 |
| `integer(s, T)` | any value of integer type `T` | 0 |
| `float_range(s, lo, hi)` | a finite `f64` in `[lo, hi]` | whole numbers near 0 |
| `float_any(s, allow_nan, allow_inf)` | any `f64`, including subnormals | 0 |
| `rune_range(s, lo, hi)` | a code point, never a surrogate | `lo` |
| `ascii_string(s, min_len, max_len)` | printable ASCII | shorter strings of `a` |
| `utf8_string(s, min_len, max_len)` | valid UTF-8 from all of Unicode | shorter ASCII strings |
| `string_of(s, alphabet, min_len, max_len)` | runes from `alphabet` | the first rune |
| `arbitrary(s, T)` | any plain data type by reflection | the zero value |

`arbitrary` handles integers, floats, booleans, runes, strings, enums, bit sets, arrays, slices, structs and unions nested to any depth:

```odin
Order :: struct {
	id:    u32,
	items: []string,
	paid:  bool,
}

order := qc.arbitrary(s, Order)
```

## Combinators

Odin procedures don't capture variables, so combinators take named procedures or procedure literals. Shrinking works through every combinator without extra code.

| Declaration | Purpose |
| --- | --- |
| `slice_of(s, gen, min_len, max_len)` | A slice of values drawn with `gen` |
| `element_of(s, items)` | One element of `items`, shrinking toward the first |
| `one_of(s, T, gens..)` | The value from one of `gens`, with equal odds |
| `frequency(s, T, entries..)` | The value from one `Weighted(T)` entry, with weighted odds |
| `mapped(s, gen, f)` | `f` applied to a drawn value; Odin reserves `map` |
| `filtered(s, gen, pred, max_tries)` | A drawn value that satisfies `pred`, plus an `ok` flag |
| `maybe_of(s, gen)` | `nil` or a drawn value |
| `draw(s, gen)` | Run a custom generator and report its result as one value |

```odin
small :: proc(s: ^qc.Source) -> int { return qc.int_range(s, 0, 9) }
huge :: proc(s: ^qc.Source) -> int { return qc.int_range(s, 1_000_000, 2_000_000) }
is_odd :: proc(n: int) -> bool { return n % 2 == 1 }

mixed := qc.frequency(s, int, qc.Weighted(int){9, small}, qc.Weighted(int){1, huge})
either := qc.one_of(s, int, small, huge)
doubled := qc.mapped(s, small, proc(n: int) -> int { return n * 2 })
odd, ok := qc.filtered(s, small, is_odd)
```

Inside a property, `assume(s, cond)` discards cases that don't meet a precondition, and `note(s, args..)` adds a line to the counterexample report.

## Running properties

| Declaration | Purpose | Allocates | Free with |
| --- | --- | --- | --- |
| `check(t, property, config)` | Run inside `@(test)` and report through `t` | Not after it returns | Not needed |
| `run(property, config, allocator)` | Run and return a `Result` | Yes | `result_destroy` |
| `replay(property, choices, config, allocator)` | Rerun one recorded case, such as `Result.choices` | Not after it returns | Not needed |
| `Config` | Cases, seed, shrink budget, discard limit, `user_data` | No | Not needed |
| `Result` | Status, seed, counts, counterexample and choices | Owns memory | `result_destroy` |
| `Error` | Union of `Config_Error`, `Generator_Error` and `runtime.Allocator_Error` | No | Not needed |

Use `run` when you want the counterexample as data:

```odin
result, err := qc.run(round_trip, {cases = 500, seed = 2026})
defer qc.result_destroy(&result)
if err == nil && result.status == .Failed {
	fmt.print(result.counterexample)
}
```

## Examples

Each directory under `examples/` is a runnable program:

```sh
odin run examples/basic
```

`examples/basic` finds the bug in a run-length encoder that assumes single-digit counts and shrinks the input to ten copies of `a`.

## Design notes

- Shrinking needs no extra code. Generators record each random decision as a bounded choice, and the shrinker simplifies that one sequence. Values built with `mapped`, `filtered` or a custom generator therefore shrink without a hand-written shrinker, and a shrunk value always meets the same constraints as a generated one.
- Runs are deterministic. A run with the same seed and property gives the same counterexample. `check` uses the test runner's seed when `Config.seed` is 0, and prints the seed when a property fails.
- Each case draws into an arena that the runner resets after the case. Inside a property, `context.allocator` is that arena, so properties never free what they draw. Code under test may still call `free`, `delete` or `free_all` on it: those calls succeed and do nothing.
- Malformed generator arguments, such as `lo > hi`, an empty alphabet or a nil generator, never panic. The generator records a `Generator_Error`, and `run` stops and returns it.
- The package keeps no global mutable state. A `Source` is safe to use from one thread at a time, and separate runs may happen on separate threads.

## Testing

```sh
odin check . -vet -strict-style -disallow-do -no-entry-point
odin test tests -vet -strict-style -disallow-do
vale sync && vale *.md
```

## Contributing

Read [CONTRIBUTING.md](CONTRIBUTING.md). Commits follow Conventional Commits, and every change that users can see gets a line in [CHANGELOG.md](CHANGELOG.md).

## License

MIT. See [LICENSE](LICENSE).
