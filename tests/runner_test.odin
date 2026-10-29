package quickcheck_tests

import qc ".."
import "core:slice"
import "core:testing"

@(test)
test_run_passes_and_counts_cases :: proc(t: ^testing.T) {
	track := track_begin()
	context.allocator = mem_tracking(&track)
	defer track_end(t, &track)
	result, err := qc.run(proc(s: ^qc.Source) -> bool {
		x := qc.int_range(s, 0, 1000)
		return x + 0 == x
	}, {cases = 250})
	defer qc.result_destroy(&result)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, result.status, qc.Status.Passed)
	testing.expect_value(t, result.cases, 250)
	testing.expect_value(t, result.discarded, 0)
	testing.expect_value(t, result.counterexample, "")
	testing.expect_value(t, len(result.choices), 0)
}

@(test)
test_run_uses_defaults_for_zero_config :: proc(t: ^testing.T) {
	track := track_begin()
	context.allocator = mem_tracking(&track)
	defer track_end(t, &track)
	result, err := qc.run(proc(s: ^qc.Source) -> bool {
		return qc.boolean(s) || true
	})
	defer qc.result_destroy(&result)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, result.cases, qc.DEFAULT_CASES)
	testing.expect_value(t, result.seed, u64(qc.DEFAULT_SEED))
}

sorted_is_reversed :: proc(s: ^qc.Source) -> bool {
	xs := qc.slice_of(s, gen_percent, 0, 20)
	ys := slice.clone(xs)
	slice.reverse(ys)
	return slice.equal(xs, ys)
}

@(test)
test_run_is_deterministic_for_a_seed :: proc(t: ^testing.T) {
	track := track_begin()
	context.allocator = mem_tracking(&track)
	defer track_end(t, &track)
	a, aerr := qc.run(sorted_is_reversed, {seed = 1234})
	defer qc.result_destroy(&a)
	b, berr := qc.run(sorted_is_reversed, {seed = 1234})
	defer qc.result_destroy(&b)
	testing.expect_value(t, aerr, nil)
	testing.expect_value(t, berr, nil)
	testing.expect_value(t, a.status, qc.Status.Failed)
	testing.expect_value(t, a.counterexample, b.counterexample)
	testing.expect_value(t, a.cases, b.cases)
	testing.expect_value(t, a.shrinks, b.shrinks)
	testing.expect(t, slice.equal(a.choices, b.choices), "choices differ between identical runs")
	testing.expect_value(t, a.seed, u64(1234))
}

@(test)
test_run_shrinks_palindrome_counterexample :: proc(t: ^testing.T) {
	track := track_begin()
	context.allocator = mem_tracking(&track)
	defer track_end(t, &track)
	for seed in 1 ..= u64(5) {
		expect_counterexample(t, sorted_is_reversed, "draw 1: [0, 1]\n", {seed = seed})
	}
}

@(test)
test_run_shrinks_pair_to_a_local_minimum :: proc(t: ^testing.T) {
	track := track_begin()
	context.allocator = mem_tracking(&track)
	defer track_end(t, &track)
	result, err := qc.run(proc(s: ^qc.Source) -> bool {
		a := qc.int_range(s, 0, 100)
		b := qc.int_range(s, 0, 100)
		return a + b <= 100
	}, {cases = 1000})
	defer qc.result_destroy(&result)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, result.status, qc.Status.Failed)
	ok, rerr := qc.replay(proc(s: ^qc.Source) -> bool {
		a := qc.int_range(s, 0, 100)
		b := qc.int_range(s, 0, 100)
		return a + b != 101
	}, result.choices)
	testing.expect_value(t, rerr, nil)
	testing.expect(t, !ok, "the shrunk pair should sum to exactly 101")
}

@(test)
test_run_rejects_nil_property :: proc(t: ^testing.T) {
	track := track_begin()
	context.allocator = mem_tracking(&track)
	defer track_end(t, &track)
	expect_run_error(t, nil, qc.Config_Error.Nil_Property)
	_, err := qc.replay(nil, nil)
	testing.expect_value(t, err, qc.Error(qc.Config_Error.Nil_Property))
}

always_true :: proc(s: ^qc.Source) -> bool {
	return true
}

@(test)
test_run_rejects_negative_config :: proc(t: ^testing.T) {
	track := track_begin()
	context.allocator = mem_tracking(&track)
	defer track_end(t, &track)
	expect_run_error(t, always_true, qc.Config_Error.Negative_Cases, {cases = -1})
	expect_run_error(t, always_true, qc.Config_Error.Negative_Max_Shrinks, {max_shrinks = -1})
	expect_run_error(t, always_true, qc.Config_Error.Negative_Max_Discards, {max_discards = -5})
	expect_run_error(t, always_true, qc.Config_Error.Negative_Max_Choices, {max_choices = -1})
}

@(test)
test_run_no_shrink_keeps_first_failure :: proc(t: ^testing.T) {
	track := track_begin()
	context.allocator = mem_tracking(&track)
	defer track_end(t, &track)
	result, err := qc.run(proc(s: ^qc.Source) -> bool {
		return qc.integer(s, u32) < 1000
	}, {no_shrink = true, seed = 99})
	defer qc.result_destroy(&result)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, result.status, qc.Status.Failed)
	testing.expect_value(t, result.shrinks, 0)
	testing.expect_value(t, result.shrink_calls, 0)
	testing.expect(t, result.counterexample != "draw 1: 1000\n", "no_shrink still shrank")
}

@(test)
test_run_respects_max_shrinks :: proc(t: ^testing.T) {
	track := track_begin()
	context.allocator = mem_tracking(&track)
	defer track_end(t, &track)
	result, err := qc.run(proc(s: ^qc.Source) -> bool {
		return len(qc.slice_of(s, gen_percent, 0, 100)) < 5
	}, {max_shrinks = 3})
	defer qc.result_destroy(&result)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, result.status, qc.Status.Failed)
	testing.expect(t, result.shrink_calls <= 3, "shrinking ignored max_shrinks")
}

@(test)
test_run_reports_property_without_draws :: proc(t: ^testing.T) {
	track := track_begin()
	context.allocator = mem_tracking(&track)
	defer track_end(t, &track)
	expect_counterexample(t, proc(s: ^qc.Source) -> bool {
		return false
	}, "(the property drew no values)\n")
}

@(test)
test_assume_discards_cases :: proc(t: ^testing.T) {
	track := track_begin()
	context.allocator = mem_tracking(&track)
	defer track_end(t, &track)
	result, err := qc.run(proc(s: ^qc.Source) -> bool {
		d := qc.int_range(s, -3, 3)
		if !qc.assume(s, d != 0) {
			return false // ignored: the case is discarded
		}
		return 12 / d * d == 12
	}, {cases = 200})
	defer qc.result_destroy(&result)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, result.status, qc.Status.Passed)
	testing.expect(t, result.discarded > 0, "assume never discarded a case")
}

@(test)
test_assume_always_false_gives_up :: proc(t: ^testing.T) {
	track := track_begin()
	context.allocator = mem_tracking(&track)
	defer track_end(t, &track)
	result, err := qc.run(proc(s: ^qc.Source) -> bool {
		return qc.assume(s, false)
	}, {cases = 5, max_discards = 7})
	defer qc.result_destroy(&result)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, result.status, qc.Status.Gave_Up)
	testing.expect_value(t, result.discarded, 7)
}

@(test)
test_max_choices_discards_runaway_cases :: proc(t: ^testing.T) {
	track := track_begin()
	context.allocator = mem_tracking(&track)
	defer track_end(t, &track)
	result, err := qc.run(proc(s: ^qc.Source) -> bool {
		for _ in 0 ..< 100 {
			_ = qc.boolean(s)
		}
		return true
	}, {cases = 3, max_choices = 10})
	defer qc.result_destroy(&result)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, result.status, qc.Status.Gave_Up)
}

Counter :: struct {
	calls: int,
}

@(test)
test_user_data_reaches_the_property :: proc(t: ^testing.T) {
	track := track_begin()
	context.allocator = mem_tracking(&track)
	defer track_end(t, &track)
	counter: Counter
	expect_passes(t, proc(s: ^qc.Source) -> bool {
		(^Counter)(s.user_data).calls += 1
		return true
	}, {cases = 42, user_data = &counter})
	testing.expect_value(t, counter.calls, 42)
}

@(test)
test_flaky_property_is_flagged :: proc(t: ^testing.T) {
	track := track_begin()
	context.allocator = mem_tracking(&track)
	defer track_end(t, &track)
	counter: Counter
	result, err := qc.run(proc(s: ^qc.Source) -> bool {
		c := (^Counter)(s.user_data)
		c.calls += 1
		return c.calls > 1
	}, {user_data = &counter})
	defer qc.result_destroy(&result)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, result.status, qc.Status.Failed)
	testing.expect(t, result.flaky, "a property that fails once should be flagged as flaky")
}

@(test)
test_replay_reproduces_failure :: proc(t: ^testing.T) {
	track := track_begin()
	context.allocator = mem_tracking(&track)
	defer track_end(t, &track)
	prop :: proc(s: ^qc.Source) -> bool {
		return qc.int_range(s, 0, 1_000_000) < 777
	}
	result, err := qc.run(prop)
	defer qc.result_destroy(&result)
	testing.expect_value(t, err, nil)
	ok, rerr := qc.replay(prop, result.choices)
	testing.expect_value(t, rerr, nil)
	testing.expect(t, !ok, "replay of the counterexample passed")
	ok, rerr = qc.replay(prop, []u64{776})
	testing.expect_value(t, rerr, nil)
	testing.expect(t, ok, "replay of a passing case failed")
}

@(test)
test_replay_clamps_out_of_range_choices :: proc(t: ^testing.T) {
	track := track_begin()
	context.allocator = mem_tracking(&track)
	defer track_end(t, &track)
	ok, err := qc.replay(proc(s: ^qc.Source) -> bool {
		return qc.int_range(s, 0, 9) == 9
	}, []u64{1 << 40})
	testing.expect_value(t, err, nil)
	testing.expect(t, ok, "an out-of-range choice should clamp to the upper bound")
}

@(test)
test_run_survives_allocation_failure :: proc(t: ^testing.T) {
	result, err := qc.run(always_true, {}, failing_allocator())
	testing.expect_value(t, err, qc.Error(.Out_Of_Memory))
	qc.result_destroy(&result)
}

@(test)
test_generator_reports_allocation_failure :: proc(t: ^testing.T) {
	track := track_begin()
	context.allocator = mem_tracking(&track)
	defer track_end(t, &track)
	result, err := qc.run(proc(s: ^qc.Source) -> bool {
		s.allocator = failing_allocator()
		_ = qc.ascii_string(s, 1, 5)
		return true
	})
	defer qc.result_destroy(&result)
	testing.expect_value(t, err, qc.Error(.Out_Of_Memory))
}

@(test)
test_source_error_exposes_generator_errors :: proc(t: ^testing.T) {
	track := track_begin()
	context.allocator = mem_tracking(&track)
	defer track_end(t, &track)
	counter: Counter
	expect_run_error(t, proc(s: ^qc.Source) -> bool {
		_ = qc.int_range(s, 3, 1)
		if qc.source_error(s) == qc.Generator_Error.Invalid_Range {
			(^Counter)(s.user_data).calls += 1
		}
		return true
	}, qc.Generator_Error.Invalid_Range, {user_data = &counter})
	testing.expect_value(t, counter.calls, 1)
}

@(test)
test_check_passes_holding_property :: proc(t: ^testing.T) {
	track := track_begin()
	context.allocator = mem_tracking(&track)
	defer track_end(t, &track)
	ok := qc.check(t, proc(s: ^qc.Source) -> bool {
		xs := qc.slice_of(s, gen_percent, 0, 30)
		slice.sort(xs)
		return slice.is_sorted(xs)
	})
	testing.expect(t, ok, "check returned false for a holding property")
}

@(test)
test_result_destroy_accepts_zero_and_nil :: proc(t: ^testing.T) {
	r: qc.Result
	qc.result_destroy(&r)
	qc.result_destroy(nil)
	testing.expect_value(t, r.status, qc.Status.Passed)
}
