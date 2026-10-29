package quickcheck_tests

import qc ".."
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
