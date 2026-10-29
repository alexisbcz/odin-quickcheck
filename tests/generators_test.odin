package quickcheck_tests

import qc ".."
import "core:math"
import "core:testing"
import "core:unicode/utf8"

@(test)
test_int_range_stays_in_positive_bounds :: proc(t: ^testing.T) {
	track := track_begin()
	context.allocator = mem_tracking(&track)
	defer track_end(t, &track)
	expect_passes(t, proc(s: ^qc.Source) -> bool {
		x := qc.int_range(s, 10, 20)
		return x >= 10 && x <= 20
	}, {cases = 500})
}

@(test)
test_int_range_stays_in_negative_bounds :: proc(t: ^testing.T) {
	track := track_begin()
	context.allocator = mem_tracking(&track)
	defer track_end(t, &track)
	expect_passes(t, proc(s: ^qc.Source) -> bool {
		x := qc.int_range(s, -20, -10)
		return x >= -20 && x <= -10
	}, {cases = 500})
}

@(test)
test_int_range_single_value :: proc(t: ^testing.T) {
	track := track_begin()
	context.allocator = mem_tracking(&track)
	defer track_end(t, &track)
	expect_passes(t, proc(s: ^qc.Source) -> bool {
		return qc.int_range(s, 7, 7) == 7 && qc.int_range(s, -3, -3) == -3
	})
}

@(test)
test_int_range_shrinks_to_lower_bound :: proc(t: ^testing.T) {
	track := track_begin()
	context.allocator = mem_tracking(&track)
	defer track_end(t, &track)
	expect_counterexample(t, proc(s: ^qc.Source) -> bool {
		_ = qc.int_range(s, 5, 100)
		return false
	}, "draw 1: 5\n")
}

@(test)
test_int_range_shrinks_to_upper_bound_when_negative :: proc(t: ^testing.T) {
	track := track_begin()
	context.allocator = mem_tracking(&track)
	defer track_end(t, &track)
	expect_counterexample(t, proc(s: ^qc.Source) -> bool {
		_ = qc.int_range(s, -100, -5)
		return false
	}, "draw 1: -5\n")
}

@(test)
test_int_range_shrinks_to_boundary_of_failure :: proc(t: ^testing.T) {
	track := track_begin()
	context.allocator = mem_tracking(&track)
	defer track_end(t, &track)
	expect_counterexample(t, proc(s: ^qc.Source) -> bool {
		return qc.int_range(s, -1000, 1000) < 42
	}, "draw 1: 42\n")
	expect_counterexample(t, proc(s: ^qc.Source) -> bool {
		return qc.int_range(s, -1000, 1000) > -17
	}, "draw 1: -17\n")
}

@(test)
test_int_range_rejects_inverted_bounds :: proc(t: ^testing.T) {
	track := track_begin()
	context.allocator = mem_tracking(&track)
	defer track_end(t, &track)
	expect_run_error(t, proc(s: ^qc.Source) -> bool {
		_ = qc.int_range(s, 5, 4)
		return true
	}, qc.Generator_Error.Invalid_Range)
}

@(test)
test_integer_full_i64_range_does_not_overflow :: proc(t: ^testing.T) {
	track := track_begin()
	context.allocator = mem_tracking(&track)
	defer track_end(t, &track)
	expect_counterexample(t, proc(s: ^qc.Source) -> bool {
		return qc.integer(s, i64) < 1_000_000_007
	}, "draw 1: 1000000007\n", {cases = 1000})
	expect_passes(t, proc(s: ^qc.Source) -> bool {
		x := qc.integer_range(s, min(i64), max(i64))
		y := qc.integer(s, u64)
		return x >= min(i64) && y <= max(u64)
	}, {cases = 1000})
}

// Seen records the extremes a generator produced across a run.
Seen :: struct {
	lo, hi:     i64,
	trues:      int,
	falses:     int,
	special:    int,
}

@(test)
test_integer_reaches_both_ends_of_small_types :: proc(t: ^testing.T) {
	track := track_begin()
	context.allocator = mem_tracking(&track)
	defer track_end(t, &track)
	seen := Seen{max(i64), min(i64), 0, 0, 0}
	expect_passes(t, proc(s: ^qc.Source) -> bool {
		seen := (^Seen)(s.user_data)
		v := i64(qc.integer(s, i8))
		seen.lo = min(seen.lo, v)
		seen.hi = max(seen.hi, v)
		return v >= -128 && v <= 127
	}, {cases = 2000, user_data = &seen})
	testing.expect_value(t, seen.lo, -128)
	testing.expect_value(t, seen.hi, 127)
}

@(test)
test_integer_unsigned_shrinks_to_zero :: proc(t: ^testing.T) {
	track := track_begin()
	context.allocator = mem_tracking(&track)
	defer track_end(t, &track)
	expect_counterexample(t, proc(s: ^qc.Source) -> bool {
		_ = qc.integer(s, u16)
		return false
	}, "draw 1: 0\n")
}

@(test)
test_boolean_produces_both_values :: proc(t: ^testing.T) {
	track := track_begin()
	context.allocator = mem_tracking(&track)
	defer track_end(t, &track)
	seen: Seen
	expect_passes(t, proc(s: ^qc.Source) -> bool {
		seen := (^Seen)(s.user_data)
		if qc.boolean(s) {
			seen.trues += 1
		} else {
			seen.falses += 1
		}
		return true
	}, {cases = 200, user_data = &seen})
	testing.expect(t, seen.trues > 50 && seen.falses > 50, "boolean is lopsided")
}

@(test)
test_boolean_shrinks_to_false :: proc(t: ^testing.T) {
	track := track_begin()
	context.allocator = mem_tracking(&track)
	defer track_end(t, &track)
	expect_counterexample(t, proc(s: ^qc.Source) -> bool {
		_ = qc.boolean(s)
		return false
	}, "draw 1: false\n")
}

@(test)
test_float_range_stays_in_bounds :: proc(t: ^testing.T) {
	track := track_begin()
	context.allocator = mem_tracking(&track)
	defer track_end(t, &track)
	expect_passes(t, proc(s: ^qc.Source) -> bool {
		a := qc.float_range(s, -2.5, 7.25)
		b := qc.float_range(s, 0.125, 0.5)
		c := qc.float_range(s, -1e300, -1e299)
		d := qc.float_range(s, -math.F64_MAX, math.F64_MAX)
		return a >= -2.5 && a <= 7.25 && b >= 0.125 && b <= 0.5 && c >= -1e300 && c <= -1e299 && !math.is_inf(d)
	}, {cases = 1000})
}

@(test)
test_float_range_shrinks_to_whole_number :: proc(t: ^testing.T) {
	track := track_begin()
	context.allocator = mem_tracking(&track)
	defer track_end(t, &track)
	expect_counterexample(t, proc(s: ^qc.Source) -> bool {
		return qc.float_range(s, 0, 100) <= 10.5
	}, "draw 1: 11\n")
}

@(test)
test_float_range_rejects_nan_and_infinite_bounds :: proc(t: ^testing.T) {
	track := track_begin()
	context.allocator = mem_tracking(&track)
	defer track_end(t, &track)
	expect_run_error(t, proc(s: ^qc.Source) -> bool {
		_ = qc.float_range(s, math.nan_f64(), 1)
		return true
	}, qc.Generator_Error.Invalid_Range)
	expect_run_error(t, proc(s: ^qc.Source) -> bool {
		_ = qc.float_range(s, 0, math.inf_f64(1))
		return true
	}, qc.Generator_Error.Invalid_Range)
	expect_run_error(t, proc(s: ^qc.Source) -> bool {
		_ = qc.float_range(s, 2, 1)
		return true
	}, qc.Generator_Error.Invalid_Range)
}

@(test)
test_float_any_is_finite_by_default :: proc(t: ^testing.T) {
	track := track_begin()
	context.allocator = mem_tracking(&track)
	defer track_end(t, &track)
	expect_passes(t, proc(s: ^qc.Source) -> bool {
		f := qc.float_any(s)
		return !math.is_nan(f) && !math.is_inf(f)
	}, {cases = 3000})
}

@(test)
test_float_any_can_produce_nan_and_infinity :: proc(t: ^testing.T) {
	track := track_begin()
	context.allocator = mem_tracking(&track)
	defer track_end(t, &track)
	seen: Seen
	expect_passes(t, proc(s: ^qc.Source) -> bool {
		seen := (^Seen)(s.user_data)
		f := qc.float_any(s, allow_nan = true, allow_inf = true)
		if math.is_nan(f) {
			seen.trues += 1
		}
		if math.is_inf(f) {
			seen.special += 1
		}
		return true
	}, {cases = 3000, user_data = &seen})
	testing.expect(t, seen.trues > 0, "float_any never produced NaN")
	testing.expect(t, seen.special > 0, "float_any never produced an infinity")
}

@(test)
test_rune_range_skips_surrogates :: proc(t: ^testing.T) {
	track := track_begin()
	context.allocator = mem_tracking(&track)
	defer track_end(t, &track)
	expect_passes(t, proc(s: ^qc.Source) -> bool {
		r := qc.rune_range(s, 0xD000, 0xE800)
		ascii := qc.rune_range(s, 'a', 'z')
		return r >= 0xD000 && r <= 0xE800 && (r < 0xD800 || r > 0xDFFF) && ascii >= 'a' && ascii <= 'z'
	}, {cases = 2000})
}

@(test)
test_rune_range_rejects_invalid_ranges :: proc(t: ^testing.T) {
	track := track_begin()
	context.allocator = mem_tracking(&track)
	defer track_end(t, &track)
	expect_run_error(t, proc(s: ^qc.Source) -> bool {
		_ = qc.rune_range(s, 'z', 'a')
		return true
	}, qc.Generator_Error.Invalid_Range)
	expect_run_error(t, proc(s: ^qc.Source) -> bool {
		_ = qc.rune_range(s, 0xD800, 0xDFFF)
		return true
	}, qc.Generator_Error.Invalid_Range)
	expect_run_error(t, proc(s: ^qc.Source) -> bool {
		_ = qc.rune_range(s, 0, utf8.MAX_RUNE + 1)
		return true
	}, qc.Generator_Error.Invalid_Range)
}

@(test)
test_ascii_string_respects_length_and_alphabet :: proc(t: ^testing.T) {
	track := track_begin()
	context.allocator = mem_tracking(&track)
	defer track_end(t, &track)
	expect_passes(t, proc(s: ^qc.Source) -> bool {
		str := qc.ascii_string(s, 2, 12)
		if len(str) < 2 || len(str) > 12 {
			return false
		}
		for c in transmute([]u8)str {
			if c < 0x20 || c > 0x7E {
				return false
			}
		}
		return true
	}, {cases = 500})
}

@(test)
test_ascii_string_shrinks_to_shortest_failing :: proc(t: ^testing.T) {
	track := track_begin()
	context.allocator = mem_tracking(&track)
	defer track_end(t, &track)
	expect_counterexample(t, proc(s: ^qc.Source) -> bool {
		return len(qc.ascii_string(s, 0, 20)) < 3
	}, "draw 1: \"aaa\"\n")
}

@(test)
test_utf8_string_is_valid_utf8 :: proc(t: ^testing.T) {
	track := track_begin()
	context.allocator = mem_tracking(&track)
	defer track_end(t, &track)
	expect_passes(t, proc(s: ^qc.Source) -> bool {
		str := qc.utf8_string(s, 1, 30)
		n := utf8.rune_count_in_string(str)
		return utf8.valid_string(str) && n >= 1 && n <= 30
	}, {cases = 1000})
}

@(test)
test_utf8_string_shrinks_to_ascii :: proc(t: ^testing.T) {
	track := track_begin()
	context.allocator = mem_tracking(&track)
	defer track_end(t, &track)
	expect_counterexample(t, proc(s: ^qc.Source) -> bool {
		return utf8.rune_count_in_string(qc.utf8_string(s, 0, 10)) < 2
	}, "draw 1: \"aa\"\n")
}

@(test)
test_string_of_uses_only_the_alphabet :: proc(t: ^testing.T) {
	track := track_begin()
	context.allocator = mem_tracking(&track)
	defer track_end(t, &track)
	expect_passes(t, proc(s: ^qc.Source) -> bool {
		str := qc.string_of(s, "αβγ", 0, 10)
		for r in str {
			if r != 'α' && r != 'β' && r != 'γ' {
				return false
			}
		}
		return utf8.rune_count_in_string(str) <= 10
	}, {cases = 500})
	expect_counterexample(t, proc(s: ^qc.Source) -> bool {
		return len(qc.string_of(s, "xyz", 1, 5)) == 0
	}, "draw 1: \"x\"\n")
}

@(test)
test_string_of_rejects_bad_alphabets :: proc(t: ^testing.T) {
	track := track_begin()
	context.allocator = mem_tracking(&track)
	defer track_end(t, &track)
	expect_run_error(t, proc(s: ^qc.Source) -> bool {
		_ = qc.string_of(s, "", 0, 4)
		return true
	}, qc.Generator_Error.Empty_Alphabet)
	expect_run_error(t, proc(s: ^qc.Source) -> bool {
		_ = qc.string_of(s, "a\xffb", 0, 4)
		return true
	}, qc.Generator_Error.Empty_Alphabet)
}

@(test)
test_strings_reject_bad_lengths :: proc(t: ^testing.T) {
	track := track_begin()
	context.allocator = mem_tracking(&track)
	defer track_end(t, &track)
	expect_run_error(t, proc(s: ^qc.Source) -> bool {
		_ = qc.ascii_string(s, 5, 2)
		return true
	}, qc.Generator_Error.Invalid_Length)
	expect_run_error(t, proc(s: ^qc.Source) -> bool {
		_ = qc.utf8_string(s, -1, 2)
		return true
	}, qc.Generator_Error.Invalid_Length)
}

@(test)
test_string_shrinks_repeated_characters_together :: proc(t: ^testing.T) {
	track := track_begin()
	context.allocator = mem_tracking(&track)
	defer track_end(t, &track)
	expect_counterexample(t, proc(s: ^qc.Source) -> bool {
		str := qc.string_of(s, "ab", 0, 30)
		run := 0
		for i in 0 ..< len(str) {
			run = i > 0 && str[i] == str[i - 1] ? run + 1 : 1
			if run >= 5 {
				return false
			}
		}
		return true
	}, "draw 1: \"aaaaa\"\n")
}
