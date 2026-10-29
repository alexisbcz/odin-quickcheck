package quickcheck

import "base:runtime"
import "core:mem"
import "core:strings"
import "core:testing"

// Outcome is what one execution of the property produced.
@(private)
Outcome :: enum {
	Pass,
	Fail,
	Discard,
	Error,
}

// Runner holds the state of one run: the property, the case arena and the shrink budget.
@(private)
Runner :: struct {
	property:     Property,
	config:       Config,
	allocator:    runtime.Allocator,
	arena:        mem.Dynamic_Arena,
	source:       Source,
	best_kinds:   [dynamic]u64,
	shrink_calls: int,
	shrinks:      int,
	err:          Error,
}

// resolve_config validates `config` and replaces zero fields with defaults.
@(private)
resolve_config :: proc(config: Config) -> (resolved: Config, err: Error) {
	resolved = config
	switch {
	case config.cases < 0:
		return {}, .Negative_Cases
	case config.max_shrinks < 0:
		return {}, .Negative_Max_Shrinks
	case config.max_discards < 0:
		return {}, .Negative_Max_Discards
	case config.max_choices < 0:
		return {}, .Negative_Max_Choices
	}
	if resolved.cases == 0 {
		resolved.cases = DEFAULT_CASES
	}
	if resolved.seed == 0 {
		resolved.seed = DEFAULT_SEED
	}
	if resolved.max_shrinks == 0 {
		resolved.max_shrinks = DEFAULT_MAX_SHRINKS
	}
	if resolved.max_discards == 0 {
		resolved.max_discards = resolved.cases * DEFAULT_DISCARD_RATIO
	}
	if resolved.max_choices == 0 {
		resolved.max_choices = DEFAULT_MAX_CHOICES
	}
	return resolved, nil
}

@(private)
runner_init :: proc(r: ^Runner, property: Property, config: Config, allocator: runtime.Allocator) -> Error {
	r.property = property
	r.config = config
	r.allocator = allocator
	mem.dynamic_arena_init(&r.arena, allocator, allocator)
	r.source.choices = make([dynamic]u64, 0, 64, allocator) or_return
	r.source.kinds = make([dynamic]u64, 0, 64, allocator) or_return
	r.best_kinds = make([dynamic]u64, 0, 64, allocator) or_return
	r.source.log = strings.builder_make(allocator) or_return
	r.source.max_choices = config.max_choices
	r.source.user_data = config.user_data
	return nil
}

@(private)
runner_destroy :: proc(r: ^Runner) {
	mem.dynamic_arena_destroy(&r.arena)
	delete(r.source.choices)
	delete(r.source.kinds)
	delete(r.best_kinds)
	strings.builder_destroy(&r.source.log)
}

/*
execute runs the property once. It replays `prefix`, then draws fresh random
choices when `generating`, or zeros otherwise. The choices it made are left in
r.source.choices.
*/
@(private)
execute :: proc(r: ^Runner, prefix: []u64, generating: bool, seed: u64, recording := false) -> Outcome {
	mem.dynamic_arena_reset(&r.arena)
	s := &r.source
	clear(&s.choices)
	clear(&s.kinds)
	strings.builder_reset(&s.log)
	s.allocator = mem.dynamic_arena_allocator(&r.arena)
	s.prefix = prefix
	s.index = 0
	s.generating = generating
	rng_init(&s.rng, seed)
	s.rejected = false
	s.overrun = false
	s.err = nil
	s.depth = 0
	s.recording = recording
	s.draws = 0

	ok: bool
	{
		context.allocator = s.allocator
		ok = r.property(s)
	}
	switch {
	case s.err != nil:
		return .Error
	case s.overrun, s.rejected:
		return .Discard
	case ok:
		return .Pass
	}
	return .Fail
}

/*
run checks `property` against Config.cases random cases and, when one fails,
shrinks it to a minimal counterexample.

Inputs:
- property: the property to check.
- config: tuning knobs; the zero value uses the defaults.
- allocator: backs the case arena and the returned Result.

Returns:
- result: what happened. It owns its counterexample and choices; free them
  with result_destroy, which is also safe after an error.
- err: a Config_Error for a bad config, the first Generator_Error a case
  recorded, or an allocator error. `result` is still filled in as far as the
  run got.

Example:
	result, err := qc.run(prop, {cases = 500, seed = 42})
	defer qc.result_destroy(&result)
	if err == nil && result.status == .Failed {
		fmt.println(result.counterexample)
	}
*/
run :: proc(property: Property, config := Config{}, allocator := context.allocator) -> (result: Result, err: Error) {
	result.allocator = allocator
	if property == nil {
		return result, .Nil_Property
	}
	cfg := resolve_config(config) or_return
	result.seed = cfg.seed

	r: Runner
	defer runner_destroy(&r)
	runner_init(&r, property, cfg, allocator) or_return

	attempt := 0
	for result.cases < cfg.cases {
		if result.discarded > cfg.max_discards {
			result.status = .Gave_Up
			return result, nil
		}
		outcome := execute(&r, nil, true, case_seed(cfg.seed, attempt))
		attempt += 1
		switch outcome {
		case .Error:
			return result, r.source.err
		case .Discard:
			result.discarded += 1
		case .Pass:
			result.cases += 1
		case .Fail:
			result.cases += 1
			result.status = .Failed
			err = report_failure(&r, &result)
			return result, err
		}
	}
	result.status = .Passed
	return result, nil
}

// report_failure shrinks the failing case in r.source.choices and fills in the result.
@(private)
report_failure :: proc(r: ^Runner, result: ^Result) -> Error {
	best := make([dynamic]u64, 0, len(r.source.choices), r.allocator) or_return
	defer delete(best)
	append(&best, ..r.source.choices[:]) or_return
	append(&r.best_kinds, ..r.source.kinds[:]) or_return

	if !r.config.no_shrink {
		shrink(r, &best)
	}
	result.shrinks = r.shrinks
	result.shrink_calls = r.shrink_calls
	if r.err != nil {
		return r.err
	}

	outcome := execute(r, best[:], false, 0, recording = true)
	result.flaky = outcome != .Fail
	report := strings.to_string(r.source.log)
	if len(report) == 0 {
		report = "(the property drew no values)\n"
	}
	result.counterexample = strings.clone(report, r.allocator) or_return
	choices := make([]u64, len(best), r.allocator) or_return
	copy(choices, best[:])
	result.choices = choices
	return nil
}

// shortlex_less orders choice sequences: shorter first, then lexicographically.
@(private)
shortlex_less :: proc(a, b: []u64) -> bool {
	if len(a) != len(b) {
		return len(a) < len(b)
	}
	for i in 0 ..< len(a) {
		if a[i] != b[i] {
			return a[i] < b[i]
		}
	}
	return false
}

// budget_left reports whether shrinking may call the property again.
@(private)
budget_left :: #force_inline proc(r: ^Runner) -> bool {
	return r.shrink_calls < r.config.max_shrinks && r.err == nil
}

/*
try_candidate replays `candidate` and keeps the choices it made as the new
best when the property still fails and they're simpler than `best`.
*/
@(private)
try_candidate :: proc(r: ^Runner, candidate: []u64, best: ^[dynamic]u64) -> bool {
	if !budget_left(r) {
		return false
	}
	r.shrink_calls += 1
	if execute(r, candidate, false, 0) != .Fail {
		return false
	}
	if !shortlex_less(r.source.choices[:], best[:]) {
		return false
	}
	clear(best)
	clear(&r.best_kinds)
	if _, err := append(best, ..r.source.choices[:]); err != nil {
		r.err = err
		return false
	}
	if _, err := append(&r.best_kinds, ..r.source.kinds[:]); err != nil {
		r.err = err
		return false
	}
	r.shrinks += 1
	return true
}

/*
shrink lowers `best` toward the simplest failing choice sequence. It loops
over five passes until none of them helps or the budget runs out: delete
chunks of choices, zero chunks of choices, lower single choices, swap nearby
choices so that larger ones come later, and lower repeated choices together.
*/
@(private)
shrink :: proc(r: ^Runner, best: ^[dynamic]u64) {
	candidate := make([dynamic]u64, 0, len(best), r.allocator)
	defer delete(candidate)

	set_candidate :: proc(r: ^Runner, candidate: ^[dynamic]u64, parts: ..[]u64) -> bool {
		clear(candidate)
		for part in parts {
			if _, err := append(candidate, ..part); err != nil {
				r.err = err
				return false
			}
		}
		return true
	}

	improved := true
	for improved && budget_left(r) {
		improved = false

		// Pass 1: delete chunks, which drops elements and whole branches. A
		// chunk of 3 drops a collection element that costs a length flag, a
		// sign and a magnitude, such as a signed integer.
		for k in ([5]int{8, 4, 3, 2, 1}) {
			i := len(best) - k
			for i >= 0 && budget_left(r) {
				if !set_candidate(r, &candidate, best[:i], best[i + k:]) {
					return
				}
				if try_candidate(r, candidate[:], best) {
					improved = true
					i = min(i, len(best) - k)
				} else {
					i -= 1
				}
			}
		}

		// Pass 2: zero chunks, which resets runs of related choices together.
		for k := 8; k >= 2; k /= 2 {
			for i := 0; i + k <= len(best) && budget_left(r); i += 1 {
				all_zero := true
				for v in best[i:i + k] {
					if v != 0 {
						all_zero = false
						break
					}
				}
				if all_zero {
					continue
				}
				if !set_candidate(r, &candidate, best[:]) {
					return
				}
				for j in i ..< i + k {
					candidate[j] = 0
				}
				if try_candidate(r, candidate[:], best) {
					improved = true
				}
			}
		}

		// Pass 3: lower each choice as far as it goes. Binary search finds the
		// boundary when failure is monotonic in the choice; the short linear
		// steps after it get past values that a filter or a branch rejects.
		for i := 0; i < len(best) && budget_left(r); i += 1 {
			for i < len(best) && best[i] != 0 && budget_left(r) {
				lo, hi := u64(0), best[i]
				for lo < hi && i < len(best) && budget_left(r) {
					mid := lo + (hi - lo) / 2
					if !set_candidate(r, &candidate, best[:]) {
						return
					}
					candidate[i] = mid
					if try_candidate(r, candidate[:], best) {
						improved = true
						hi = mid
					} else {
						lo = mid + 1
					}
				}
				stepped := false
				for d in u64(1) ..= 4 {
					if i >= len(best) || best[i] < d || !budget_left(r) {
						break
					}
					if !set_candidate(r, &candidate, best[:]) {
						return
					}
					candidate[i] -= d
					if try_candidate(r, candidate[:], best) {
						improved = true
						stepped = true
						break
					}
				}
				if !stepped {
					break
				}
			}
		}

		// Pass 4: move larger choices later by swapping nearby pairs, which
		// turns [1, 0] into [0, 1] where only the order matters.
		for i := 0; i < len(best) && budget_left(r); i += 1 {
			for j := i + 1; j < min(len(best), i + 9) && budget_left(r); j += 1 {
				if i >= len(best) || j >= len(best) || best[i] <= best[j] {
					continue
				}
				if !set_candidate(r, &candidate, best[:]) {
					return
				}
				candidate[i], candidate[j] = candidate[j], candidate[i]
				if try_candidate(r, candidate[:], best) {
					improved = true
				}
			}
		}

		// Pass 5: lower every copy of a repeated choice of the same kind at
		// once, which turns "bbbb" into "aaaa" when the property needs a run.
		for i := 0; i < len(best) && budget_left(r); i += 1 {
			v, kind := best[i], r.best_kinds[i]
			if v == 0 || !has_twin(best[:], r.best_kinds[:], i) {
				continue
			}
			for target in ([3]u64{0, v / 2, v - 1}) {
				if target >= v || i >= len(best) || best[i] != v || !budget_left(r) {
					break
				}
				if !set_candidate(r, &candidate, best[:]) {
					return
				}
				for j in i ..< len(candidate) {
					if candidate[j] == v && r.best_kinds[j] == kind {
						candidate[j] = target
					}
				}
				if try_candidate(r, candidate[:], best) {
					improved = true
					break
				}
			}
		}
	}
}

// has_twin reports whether a later choice has the same value and kind as choice `i`.
@(private)
has_twin :: proc(choices, kinds: []u64, i: int) -> bool {
	for j in i + 1 ..< len(choices) {
		if choices[j] == choices[i] && kinds[j] == kinds[i] {
			return true
		}
	}
	return false
}

/*
replay reruns `property` on one recorded choice sequence, such as
Result.choices, and returns whether the property held. Use it to pin a
counterexample in a regression test.

Returns:
- ok: the property's verdict on that case. A discarded case counts as passing.
- err: the first generator error of the case, `.Nil_Property` or an allocator error.
*/
replay :: proc(property: Property, choices: []u64, config := Config{}, allocator := context.allocator) -> (ok: bool, err: Error) {
	if property == nil {
		return false, .Nil_Property
	}
	cfg := resolve_config(config) or_return
	r: Runner
	defer runner_destroy(&r)
	runner_init(&r, property, cfg, allocator) or_return
	switch execute(&r, choices, false, 0) {
	case .Error:
		return false, r.source.err
	case .Fail:
		return false, nil
	case .Pass, .Discard:
	}
	return true, nil
}

/*
check runs `property` and reports a failure through `t`. It is the usual way
to use this package from an `@(test)` procedure.

When Config.seed is 0, check uses the test runner's seed, so a failure
reproduces when you pass the same `-define:ODIN_TEST_RANDOM_SEED` again, or
the seed printed in the failure message as Config.seed.

Returns: `true` when the property held for every case.

Example:
	@(test)
	test_reverse_twice :: proc(t: ^testing.T) {
		qc.check(t, proc(s: ^qc.Source) -> bool {
			xs := qc.slice_of(s, gen_digit, 0, 20)
			ys := slice.clone(xs)
			slice.reverse(ys)
			slice.reverse(ys)
			return slice.equal(xs, ys)
		})
	}
*/
check :: proc(t: ^testing.T, property: Property, config := Config{}, loc := #caller_location) -> bool {
	cfg := config
	if cfg.seed == 0 {
		cfg.seed = t.seed
	}
	result, err := run(property, cfg, context.allocator)
	defer result_destroy(&result)
	if err != nil {
		testing.expectf(t, false, "quickcheck: run failed: %v", err, loc = loc)
		return false
	}
	switch result.status {
	case .Passed:
		return true
	case .Failed:
		flaky := result.flaky ? "\nwarning: the minimal case passed on replay, so the property is not deterministic" : ""
		testing.expectf(
			t,
			false,
			"quickcheck: property failed after %d case(s) and %d shrink(s), seed %d\n%s%s",
			result.cases,
			result.shrinks,
			result.seed,
			strings.trim_right(result.counterexample, "\n"),
			flaky,
			loc = loc,
		)
	case .Gave_Up:
		testing.expectf(
			t,
			false,
			"quickcheck: gave up after %d discarded case(s) with %d passing, seed %d; loosen assume or filtered",
			result.discarded,
			result.cases,
			result.seed,
			loc = loc,
		)
	}
	return false
}
