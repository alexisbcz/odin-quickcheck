/*
Package quickcheck is property-based testing for `core:testing`.

A property is a procedure that draws random inputs from a Source and returns
`true` when the code under test behaves. The runner calls it many times with
fresh inputs. When a case fails, the runner shrinks it: it replays the property
with simpler and simpler inputs until no simpler failing input exists, then
reports that minimal counterexample together with the seed that found it.

Shrinking is integrated. Every generator records the choices it makes in one
flat sequence, and the shrinker simplifies that sequence instead of the values
themselves. Generators built with combinators such as mapped, filtered, one_of
and frequency therefore shrink for free, and a shrunk value always satisfies
the same constraints as a generated one.

Memory: every value a generator returns lives in a per-case arena that the
runner frees when the case ends. Inside a property, `context.allocator` is that
same arena, so properties never need to free what they draw.

Example:
	import qc "shared:quickcheck"
	import "core:slice"
	import "core:testing"

	@(test)
	test_sort_is_idempotent :: proc(t: ^testing.T) {
		qc.check(t, proc(s: ^qc.Source) -> bool {
			xs := qc.slice_of(s, proc(s: ^qc.Source) -> int {
				return qc.int_range(s, -100, 100)
			}, 0, 20)
			slice.sort(xs)
			return slice.is_sorted(xs)
		})
	}
*/
package quickcheck

import "base:runtime"

// DEFAULT_CASES is the number of passing cases a run needs when Config.cases is 0.
DEFAULT_CASES :: 100

// DEFAULT_SEED seeds a run when Config.seed is 0 and no test seed is available.
DEFAULT_SEED :: 0x5eed_0f_0d1_c4ec

// DEFAULT_MAX_SHRINKS caps property calls during shrinking when Config.max_shrinks is 0.
DEFAULT_MAX_SHRINKS :: 2000

// DEFAULT_MAX_CHOICES caps the choices one case may make when Config.max_choices is 0.
DEFAULT_MAX_CHOICES :: 8192

// DEFAULT_DISCARD_RATIO sets Config.max_discards to `cases * DEFAULT_DISCARD_RATIO` when it is 0.
DEFAULT_DISCARD_RATIO :: 10

// Config_Error lists the ways a Config or a call to run can be invalid.
Config_Error :: enum {
	None,
	// run or check received a nil property.
	Nil_Property,
	// Config.cases was negative.
	Negative_Cases,
	// Config.max_shrinks was negative.
	Negative_Max_Shrinks,
	// Config.max_discards was negative.
	Negative_Max_Discards,
	// Config.max_choices was negative.
	Negative_Max_Choices,
}

/*
Generator_Error lists the ways a generator call can be malformed. A generator
that receives bad arguments never panics: it returns a zero value and records
the error on the Source, and the runner stops and returns it from run.
*/
Generator_Error :: enum {
	None,
	// A lower bound was above its upper bound, or a float bound was NaN or infinite.
	Invalid_Range,
	// A minimum length was negative or above the maximum length.
	Invalid_Length,
	// string_of received an empty alphabet, or one that is not valid UTF-8.
	Empty_Alphabet,
	// element_of or one_of received nothing to choose from.
	Empty_Choices,
	// frequency received a negative weight, a zero total or a total that overflows.
	Invalid_Weights,
	// arbitrary met a type it can't build, such as a pointer, map or procedure.
	Unsupported_Type,
}

/*
Error is the compound error type of this package. `nil` means success. Switch
on it with a type switch, or compare it against a variant such as
`Generator_Error.Invalid_Range`.
*/
Error :: union #shared_nil {
	Config_Error,
	Generator_Error,
	runtime.Allocator_Error,
}

/*
Property is the procedure under test. It draws inputs from `s` and returns
`true` when the code under test behaves for them. Odin procedures don't
capture variables, so pass outside state through Config.user_data and read it
back from Source.user_data.
*/
Property :: #type proc(s: ^Source) -> bool

/*
Config tunes a run. The zero value is a sensible default: every field that is
0 takes the matching DEFAULT_ constant.
*/
Config :: struct {
	// cases is how many non-discarded cases must pass. 0 means DEFAULT_CASES.
	cases:        int,
	// seed makes the run reproducible. 0 means the test runner's seed in check, or DEFAULT_SEED in run.
	seed:         u64,
	// max_shrinks caps property calls while shrinking. 0 means DEFAULT_MAX_SHRINKS.
	max_shrinks:  int,
	// max_discards is how many rejected cases the run tolerates before it gives up. 0 means `cases * DEFAULT_DISCARD_RATIO`.
	max_discards: int,
	// max_choices caps the choices a single case may make; a case that needs more is discarded. 0 means DEFAULT_MAX_CHOICES.
	max_choices:  int,
	// no_shrink reports the first failing case as found, without shrinking it.
	no_shrink:    bool,
	// user_data is copied into Source.user_data for every case.
	user_data:    rawptr,
}

// Status is the outcome of a run that returned no Error.
Status :: enum {
	// Every case passed.
	Passed,
	// A case failed; Result.counterexample describes the minimal one.
	Failed,
	// Too many cases were discarded by assume, filtered or max_choices before enough passed.
	Gave_Up,
}

/*
Result describes a finished run. It owns `counterexample` and `choices`;
release both with result_destroy.
*/
Result :: struct {
	// status says whether the property held.
	status:          Status,
	// seed is the seed the run used; pass it back in Config.seed to reproduce the run.
	seed:            u64,
	// cases counts the cases that ran to completion, including the failing one.
	cases:           int,
	// discarded counts the cases thrown away by assume, filtered or max_choices.
	discarded:       int,
	// shrinks counts the successful shrink steps.
	shrinks:         int,
	// shrink_calls counts the property calls made while shrinking.
	shrink_calls:    int,
	// counterexample lists the values the minimal failing case drew, one per line. Empty unless status is .Failed.
	counterexample:  string,
	// choices is the minimal failing choice sequence. Pass it to replay to rerun that exact case.
	choices:         []u64,
	// flaky is true when the minimal case passed on its final replay, which means the property isn't deterministic.
	flaky:           bool,
	// allocator owns counterexample and choices.
	allocator:       runtime.Allocator,
}

// result_destroy frees the memory a Result owns and zeroes it. It accepts a zero Result.
result_destroy :: proc(r: ^Result) {
	if r == nil {
		return
	}
	delete(r.counterexample, r.allocator)
	delete(r.choices, r.allocator)
	r^ = {}
}
