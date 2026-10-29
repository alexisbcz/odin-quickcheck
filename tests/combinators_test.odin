package quickcheck_tests

import qc ".."
import "core:fmt"
import "core:strings"
import "core:testing"

@(test)
test_slice_of_respects_length_bounds :: proc(t: ^testing.T) {
	track := track_begin()
	context.allocator = mem_tracking(&track)
	defer track_end(t, &track)
	expect_passes(t, proc(s: ^qc.Source) -> bool {
		xs := qc.slice_of(s, gen_digit, 3, 7)
		if len(xs) < 3 || len(xs) > 7 {
			return false
		}
		for x in xs {
			if x < 0 || x > 9 {
				return false
			}
		}
		return true
	}, {cases = 500})
}

@(test)
test_slice_of_fixed_length :: proc(t: ^testing.T) {
	track := track_begin()
	context.allocator = mem_tracking(&track)
	defer track_end(t, &track)
	expect_passes(t, proc(s: ^qc.Source) -> bool {
		return len(qc.slice_of(s, gen_digit, 4, 4)) == 4 && len(qc.slice_of(s, gen_digit, 0, 0)) == 0
	})
}

@(test)
test_slice_of_shrinks_to_single_minimal_element :: proc(t: ^testing.T) {
	track := track_begin()
	context.allocator = mem_tracking(&track)
	defer track_end(t, &track)
	expect_counterexample(t, proc(s: ^qc.Source) -> bool {
		for x in qc.slice_of(s, gen_percent, 0, 50) {
			if x >= 50 {
				return false
			}
		}
		return true
	}, "draw 1: [50]\n")
}

@(test)
test_slice_of_shrinks_length_to_minimum_failing :: proc(t: ^testing.T) {
	track := track_begin()
	context.allocator = mem_tracking(&track)
	defer track_end(t, &track)
	expect_counterexample(t, proc(s: ^qc.Source) -> bool {
		return len(qc.slice_of(s, gen_digit, 0, 30)) < 4
	}, "draw 1: [0, 0, 0, 0]\n")
}

@(test)
test_slice_of_rejects_bad_lengths :: proc(t: ^testing.T) {
	track := track_begin()
	context.allocator = mem_tracking(&track)
	defer track_end(t, &track)
	expect_run_error(t, proc(s: ^qc.Source) -> bool {
		_ = qc.slice_of(s, gen_digit, 3, 1)
		return true
	}, qc.Generator_Error.Invalid_Length)
	expect_run_error(t, proc(s: ^qc.Source) -> bool {
		_ = qc.slice_of(s, gen_digit, -2, 1)
		return true
	}, qc.Generator_Error.Invalid_Length)
}

@(test)
test_slice_of_strings_does_not_leak :: proc(t: ^testing.T) {
	track := track_begin()
	context.allocator = mem_tracking(&track)
	defer track_end(t, &track)
	gen_word :: proc(s: ^qc.Source) -> string {
		return qc.ascii_string(s, 0, 40)
	}
	expect_passes(t, proc(s: ^qc.Source) -> bool {
		words := qc.slice_of(s, gen_word, 0, 40)
		joined := strings.join(words, " ")
		return len(joined) >= len(words) - 1
	}, {cases = 300})
}

@(test)
test_element_of_only_returns_items :: proc(t: ^testing.T) {
	track := track_begin()
	context.allocator = mem_tracking(&track)
	defer track_end(t, &track)
	expect_passes(t, proc(s: ^qc.Source) -> bool {
		items := []string{"red", "green", "blue"}
		c := qc.element_of(s, items)
		return c == "red" || c == "green" || c == "blue"
	})
	expect_counterexample(t, proc(s: ^qc.Source) -> bool {
		items := []string{"red", "green", "blue"}
		_ = qc.element_of(s, items)
		return false
	}, "draw 1: \"red\"\n")
}

@(test)
test_element_of_rejects_empty_slice :: proc(t: ^testing.T) {
	track := track_begin()
	context.allocator = mem_tracking(&track)
	defer track_end(t, &track)
	expect_run_error(t, proc(s: ^qc.Source) -> bool {
		_ = qc.element_of(s, []int{})
		return true
	}, qc.Generator_Error.Empty_Choices)
}

gen_small :: proc(s: ^qc.Source) -> int {
	return qc.int_range(s, 0, 9)
}

gen_large :: proc(s: ^qc.Source) -> int {
	return qc.int_range(s, 1000, 1009)
}

@(test)
test_one_of_uses_every_generator :: proc(t: ^testing.T) {
	track := track_begin()
	context.allocator = mem_tracking(&track)
	defer track_end(t, &track)
	seen: Seen
	expect_passes(t, proc(s: ^qc.Source) -> bool {
		seen := (^Seen)(s.user_data)
		n := qc.one_of(s, int, gen_small, gen_large)
		if n < 10 {
			seen.falses += 1
		} else {
			seen.trues += 1
		}
		return (n >= 0 && n <= 9) || (n >= 1000 && n <= 1009)
	}, {cases = 300, user_data = &seen})
	testing.expect(t, seen.trues > 0 && seen.falses > 0, "one_of skipped a generator")
}

@(test)
test_one_of_shrinks_to_first_generator :: proc(t: ^testing.T) {
	track := track_begin()
	context.allocator = mem_tracking(&track)
	defer track_end(t, &track)
	expect_counterexample(t, proc(s: ^qc.Source) -> bool {
		_ = qc.one_of(s, int, gen_large, gen_small)
		return false
	}, "draw 1: 1000\n")
}

@(test)
test_one_of_rejects_no_generators :: proc(t: ^testing.T) {
	track := track_begin()
	context.allocator = mem_tracking(&track)
	defer track_end(t, &track)
	expect_run_error(t, proc(s: ^qc.Source) -> bool {
		gens: []proc(s: ^qc.Source) -> int
		_ = qc.one_of(s, int, ..gens)
		return true
	}, qc.Generator_Error.Empty_Choices)
}

@(test)
test_frequency_never_picks_zero_weight :: proc(t: ^testing.T) {
	track := track_begin()
	context.allocator = mem_tracking(&track)
	defer track_end(t, &track)
	expect_passes(t, proc(s: ^qc.Source) -> bool {
		n := qc.frequency(s, int, qc.Weighted(int){0, gen_large}, qc.Weighted(int){5, gen_small})
		return n < 10
	}, {cases = 500})
}

@(test)
test_frequency_follows_weights :: proc(t: ^testing.T) {
	track := track_begin()
	context.allocator = mem_tracking(&track)
	defer track_end(t, &track)
	seen: Seen
	expect_passes(t, proc(s: ^qc.Source) -> bool {
		seen := (^Seen)(s.user_data)
		if qc.frequency(s, int, qc.Weighted(int){9, gen_small}, qc.Weighted(int){1, gen_large}) < 10 {
			seen.falses += 1
		} else {
			seen.trues += 1
		}
		return true
	}, {cases = 2000, user_data = &seen})
	testing.expectf(t, seen.falses > seen.trues * 4, "weights ignored: %d small, %d large", seen.falses, seen.trues)
	testing.expect(t, seen.trues > 0, "the light entry never came up")
}

@(test)
test_frequency_rejects_bad_weights :: proc(t: ^testing.T) {
	track := track_begin()
	context.allocator = mem_tracking(&track)
	defer track_end(t, &track)
	expect_run_error(t, proc(s: ^qc.Source) -> bool {
		_ = qc.frequency(s, int, qc.Weighted(int){-1, gen_small}, qc.Weighted(int){2, gen_large})
		return true
	}, qc.Generator_Error.Invalid_Weights)
	expect_run_error(t, proc(s: ^qc.Source) -> bool {
		_ = qc.frequency(s, int, qc.Weighted(int){0, gen_small}, qc.Weighted(int){0, gen_large})
		return true
	}, qc.Generator_Error.Invalid_Weights)
	expect_run_error(t, proc(s: ^qc.Source) -> bool {
		_ = qc.frequency(s, int, qc.Weighted(int){max(int), gen_small}, qc.Weighted(int){max(int), gen_large}, qc.Weighted(int){max(int), gen_large})
		return true
	}, qc.Generator_Error.Invalid_Weights)
	expect_run_error(t, proc(s: ^qc.Source) -> bool {
		_ = qc.frequency(s, int, qc.Weighted(int){1, nil})
		return true
	}, qc.Generator_Error.Invalid_Weights)
	expect_run_error(t, proc(s: ^qc.Source) -> bool {
		entries: []qc.Weighted(int)
		_ = qc.frequency(s, int, ..entries)
		return true
	}, qc.Generator_Error.Empty_Choices)
}

@(test)
test_mapped_transforms_and_shrinks :: proc(t: ^testing.T) {
	track := track_begin()
	context.allocator = mem_tracking(&track)
	defer track_end(t, &track)
	double :: proc(n: int) -> int {
		return n * 2
	}
	expect_passes(t, proc(s: ^qc.Source) -> bool {
		return qc.mapped(s, gen_percent, double) % 2 == 0
	})
	expect_counterexample(t, proc(s: ^qc.Source) -> bool {
		return qc.mapped(s, gen_percent, double) < 15
	}, "draw 1: 16\n")
}

@(test)
test_mapped_can_change_type :: proc(t: ^testing.T) {
	track := track_begin()
	context.allocator = mem_tracking(&track)
	defer track_end(t, &track)
	expect_counterexample(t, proc(s: ^qc.Source) -> bool {
		label := qc.mapped(s, gen_percent, proc(n: int) -> string {
			return fmt.aprintf("item-%d", n)
		})
		return len(label) < 7
	}, "draw 1: \"item-10\"\n")
}

is_odd :: proc(n: int) -> bool {
	return n % 2 == 1
}

@(test)
test_filtered_values_satisfy_predicate :: proc(t: ^testing.T) {
	track := track_begin()
	context.allocator = mem_tracking(&track)
	defer track_end(t, &track)
	expect_passes(t, proc(s: ^qc.Source) -> bool {
		n, ok := qc.filtered(s, gen_percent, is_odd)
		return !ok || is_odd(n)
	}, {cases = 500})
}

@(test)
test_filtered_shrinks_within_predicate :: proc(t: ^testing.T) {
	track := track_begin()
	context.allocator = mem_tracking(&track)
	defer track_end(t, &track)
	expect_counterexample(t, proc(s: ^qc.Source) -> bool {
		n, ok := qc.filtered(s, gen_percent, is_odd)
		if !ok {
			return true
		}
		return n <= 10
	}, "draw 1: 11\n")
}

@(test)
test_filtered_impossible_predicate_gives_up :: proc(t: ^testing.T) {
	track := track_begin()
	context.allocator = mem_tracking(&track)
	defer track_end(t, &track)
	result, err := qc.run(proc(s: ^qc.Source) -> bool {
		_, ok := qc.filtered(s, gen_digit, proc(n: int) -> bool {
			return n > 100
		}, max_tries = 5)
		return !ok
	}, {cases = 10})
	defer qc.result_destroy(&result)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, result.status, qc.Status.Gave_Up)
	// The default limit is cases * DEFAULT_DISCARD_RATIO = 100, so the run gives up on discard 101.
	testing.expect_value(t, result.discarded, 101)
	testing.expect_value(t, result.cases, 0)
}

@(test)
test_maybe_of_shrinks_to_nil :: proc(t: ^testing.T) {
	track := track_begin()
	context.allocator = mem_tracking(&track)
	defer track_end(t, &track)
	expect_counterexample(t, proc(s: ^qc.Source) -> bool {
		_ = qc.maybe_of(s, gen_digit)
		return false
	}, "draw 1: nil\n")
	expect_counterexample(t, proc(s: ^qc.Source) -> bool {
		_, ok := qc.maybe_of(s, gen_digit).?
		return !ok
	}, "draw 1: 0\n")
}

Point :: struct {
	x, y: int,
}

gen_point :: proc(s: ^qc.Source) -> Point {
	return {qc.int_range(s, -50, 50), qc.int_range(s, -50, 50)}
}

@(test)
test_draw_reports_one_value_for_composite :: proc(t: ^testing.T) {
	track := track_begin()
	context.allocator = mem_tracking(&track)
	defer track_end(t, &track)
	expect_counterexample(t, proc(s: ^qc.Source) -> bool {
		p := qc.draw(s, gen_point)
		return p.x * p.x + p.y * p.y < 100
	}, "draw 1: Point{x = 0, y = 10}\n")
	expect_counterexample(t, proc(s: ^qc.Source) -> bool {
		p := gen_point(s)
		return p.x < 3
	}, "draw 1: 3\ndraw 2: 0\n")
}

@(test)
test_note_lands_in_counterexample :: proc(t: ^testing.T) {
	track := track_begin()
	context.allocator = mem_tracking(&track)
	defer track_end(t, &track)
	expect_counterexample(t, proc(s: ^qc.Source) -> bool {
		n := qc.int_range(s, 0, 100)
		qc.note(s, "square is", n * n)
		return n < 5
	}, "draw 1: 5\nsquare is 25\n")
}
