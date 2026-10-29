package quickcheck_tests

import qc ".."
import "core:math"
import "core:testing"

// Regression tests for defects found in review after 0.1.0.

@(test)
test_run_tolerates_exactly_max_discards :: proc(t: ^testing.T) {
	track := track_begin()
	context.allocator = mem_tracking(&track)
	defer track_end(t, &track)
	// The first case is discarded and every later one passes. With one
	// discard allowed, the run must go on and pass instead of giving up.
	counter: Counter
	result, err := qc.run(proc(s: ^qc.Source) -> bool {
		c := (^Counter)(s.user_data)
		c.calls += 1
		return qc.assume(s, c.calls > 1)
	}, {cases = 3, max_discards = 1, user_data = &counter})
	defer qc.result_destroy(&result)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, result.status, qc.Status.Passed)
	testing.expect_value(t, result.discarded, 1)
	testing.expect_value(t, result.cases, 3)
}

@(test)
test_arbitrary_big_endian_integers_shrink_to_boundary :: proc(t: ^testing.T) {
	track := track_begin()
	context.allocator = mem_tracking(&track)
	defer track_end(t, &track)
	expect_counterexample(t, proc(s: ^qc.Source) -> bool {
		return qc.arbitrary(s, u16be) < 1000
	}, "draw 1: 1000\n")
	expect_counterexample(t, proc(s: ^qc.Source) -> bool {
		return qc.arbitrary(s, i32be) > -1000
	}, "draw 1: -1000\n")
}

@(test)
test_arbitrary_big_endian_floats_are_finite :: proc(t: ^testing.T) {
	track := track_begin()
	context.allocator = mem_tracking(&track)
	defer track_end(t, &track)
	expect_passes(t, proc(s: ^qc.Source) -> bool {
		a := f64(qc.arbitrary(s, f32be))
		b := f64(qc.arbitrary(s, f64be))
		c := f64(qc.arbitrary(s, f16le))
		return !math.is_nan(a) && !math.is_inf(a) && !math.is_nan(b) && !math.is_inf(b) && !math.is_nan(c) && !math.is_inf(c)
	}, {cases = 2000})
	expect_counterexample(t, proc(s: ^qc.Source) -> bool {
		return qc.arbitrary(s, f32be) < 100.5
	}, "draw 1: 101\n")
}

gen_signed :: proc(s: ^qc.Source) -> int {
	return qc.int_range(s, -10_000, 10_000)
}

@(test)
test_slice_of_signed_elements_shrinks_to_one_element :: proc(t: ^testing.T) {
	track := track_begin()
	context.allocator = mem_tracking(&track)
	defer track_end(t, &track)
	// Each signed element costs three choices: a length flag, a sign and a
	// magnitude. The shrinker must be able to drop all three at once.
	expect_counterexample(t, proc(s: ^qc.Source) -> bool {
		for x in qc.slice_of(s, gen_signed, 0, 50) {
			if x > 100 {
				return false
			}
		}
		return true
	}, "draw 1: [101]\n")
}

@(test)
test_nil_procedures_are_reported_not_called :: proc(t: ^testing.T) {
	track := track_begin()
	context.allocator = mem_tracking(&track)
	defer track_end(t, &track)
	nil_gen :: proc(s: ^qc.Source) -> int {
		g: proc(s: ^qc.Source) -> int
		return qc.draw(s, g)
	}
	want := qc.Error(qc.Generator_Error.Nil_Procedure)
	expect_run_error(t, proc(s: ^qc.Source) -> bool {
		g: proc(s: ^qc.Source) -> int
		_ = qc.slice_of(s, g, 1, 3)
		return true
	}, want)
	expect_run_error(t, proc(s: ^qc.Source) -> bool {
		g: proc(s: ^qc.Source) -> int
		_ = qc.mapped(s, g, proc(n: int) -> int { return n })
		return true
	}, want)
	expect_run_error(t, proc(s: ^qc.Source) -> bool {
		f: proc(n: int) -> int
		_ = qc.mapped(s, gen_digit, f)
		return true
	}, want)
	expect_run_error(t, proc(s: ^qc.Source) -> bool {
		g: proc(s: ^qc.Source) -> int
		_, _ = qc.filtered(s, g, proc(n: int) -> bool { return true })
		return true
	}, want)
	expect_run_error(t, proc(s: ^qc.Source) -> bool {
		p: proc(n: int) -> bool
		_, _ = qc.filtered(s, gen_digit, p)
		return true
	}, want)
	expect_run_error(t, proc(s: ^qc.Source) -> bool {
		g: proc(s: ^qc.Source) -> int
		_ = qc.maybe_of(s, g)
		return true
	}, want)
	expect_run_error(t, proc(s: ^qc.Source) -> bool {
		_ = nil_gen(s)
		return true
	}, want)
}

@(test)
test_property_may_free_what_it_allocates :: proc(t: ^testing.T) {
	track := track_begin()
	context.allocator = mem_tracking(&track)
	defer track_end(t, &track)
	// Code under test often frees through context.allocator and checks the
	// result. Inside a property that is the case arena, so freeing must succeed.
	expect_passes(t, proc(s: ^qc.Source) -> bool {
		xs := qc.slice_of(s, gen_digit, 1, 5)
		p := new(int)
		if free(p) != nil {
			return false
		}
		buf := make([]byte, 10_000)
		if delete(buf) != nil {
			return false
		}
		// free_all must not release values the case already drew.
		_ = free_all(context.allocator)
		_ = make([]int, 64)
		return len(xs) >= 1 && xs[0] >= 0 && xs[0] <= 9
	})
}


Wide :: enum u16be {
	Low  = 1,
	High = 0x1234,
}

Flags :: bit_set[0 ..< 16; u16be]

@(test)
test_arbitrary_big_endian_enums_and_bit_sets_are_valid :: proc(t: ^testing.T) {
	track := track_begin()
	context.allocator = mem_tracking(&track)
	defer track_end(t, &track)
	expect_passes(t, proc(s: ^qc.Source) -> bool {
		w := qc.arbitrary(s, Wide)
		return w == .Low || w == .High
	})
	expect_counterexample(t, proc(s: ^qc.Source) -> bool {
		return 3 not_in qc.arbitrary(s, Flags)
	}, "draw 1: bit_set[0..=15; u16be]{3}\n")
}
