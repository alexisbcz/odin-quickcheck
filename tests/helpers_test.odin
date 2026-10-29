// Package quickcheck_tests holds the unit tests for quickcheck. Run them with `odin test tests`.
package quickcheck_tests

import qc ".."
import "core:log"
import "core:mem"
import "core:testing"

// track_begin starts a tracking allocator over the current context allocator.
track_begin :: proc() -> (track: mem.Tracking_Allocator) {
	mem.tracking_allocator_init(&track, context.allocator)
	return
}

// track_end fails the test when the tracking allocator saw leaks or bad frees, then destroys it.
track_end :: proc(t: ^testing.T, track: ^mem.Tracking_Allocator, loc := #caller_location) {
	testing.expectf(t, len(track.allocation_map) == 0, "leaked %d allocation(s)", len(track.allocation_map), loc = loc)
	for _, entry in track.allocation_map {
		log.errorf("leak: %d bytes at %v", entry.size, entry.location)
	}
	testing.expectf(t, len(track.bad_free_array) == 0, "%d bad free(s)", len(track.bad_free_array), loc = loc)
	mem.tracking_allocator_destroy(track)
}

// expect_passes runs `prop` and fails the test unless every case passed.
expect_passes :: proc(t: ^testing.T, prop: qc.Property, config := qc.Config{}, loc := #caller_location) {
	result, err := qc.run(prop, config)
	defer qc.result_destroy(&result)
	testing.expect_value(t, err, nil, loc = loc)
	testing.expectf(
		t,
		result.status == .Passed,
		"status %v, counterexample:\n%s",
		result.status,
		result.counterexample,
		loc = loc,
	)
}

// expect_counterexample runs `prop`, expects it to fail and compares the minimal counterexample.
expect_counterexample :: proc(t: ^testing.T, prop: qc.Property, want: string, config := qc.Config{}, loc := #caller_location) {
	result, err := qc.run(prop, config)
	defer qc.result_destroy(&result)
	testing.expect_value(t, err, nil, loc = loc)
	testing.expect_value(t, result.status, qc.Status.Failed, loc = loc)
	testing.expectf(t, result.counterexample == want, "counterexample:\n%s\nwant:\n%s", result.counterexample, want, loc = loc)
	testing.expect(t, !result.flaky, "deterministic property reported as flaky", loc = loc)
}

// expect_run_error runs `prop` and expects `want` back from run.
expect_run_error :: proc(t: ^testing.T, prop: qc.Property, want: qc.Error, config := qc.Config{}, loc := #caller_location) {
	result, err := qc.run(prop, config)
	defer qc.result_destroy(&result)
	testing.expectf(t, err == want, "got error %v, want %v", err, want, loc = loc)
}

// failing_allocator fails every allocation.
failing_allocator :: proc() -> mem.Allocator {
	fail :: proc(
		data: rawptr,
		mode: mem.Allocator_Mode,
		size, alignment: int,
		old_memory: rawptr,
		old_size: int,
		loc := #caller_location,
	) -> (
		[]byte,
		mem.Allocator_Error,
	) {
		#partial switch mode {
		case .Free, .Free_All:
			return nil, nil
		}
		return nil, .Out_Of_Memory
	}
	return {procedure = fail}
}

// gen_digit draws an int in [0, 9].
gen_digit :: proc(s: ^qc.Source) -> int {
	return qc.int_range(s, 0, 9)
}

// gen_percent draws an int in [0, 100].
gen_percent :: proc(s: ^qc.Source) -> int {
	return qc.int_range(s, 0, 100)
}

// mem_tracking returns the allocator view of `track`.
mem_tracking :: proc(track: ^mem.Tracking_Allocator) -> mem.Allocator {
	return mem.tracking_allocator(track)
}
