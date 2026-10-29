package quickcheck_tests

import qc ".."
import "core:math"
import "core:testing"
import "core:unicode/utf8"

Color :: enum u8 {
	Red   = 3,
	Green = 7,
	Blue  = 200,
}

Order :: struct {
	id:     u32,
	color:  Color,
	paid:   bool,
	tags:   []string,
	totals: [2]f64,
	code:   i16,
}

@(test)
test_arbitrary_struct_shrinks_to_zero_value :: proc(t: ^testing.T) {
	track := track_begin()
	context.allocator = mem_tracking(&track)
	defer track_end(t, &track)
	expect_counterexample(t, proc(s: ^qc.Source) -> bool {
		_ = qc.arbitrary(s, Order)
		return false
	}, "draw 1: Order{id = 0, color = \"Red\", paid = false, tags = [], totals = [0, 0], code = 0}\n")
}

@(test)
test_arbitrary_struct_shrinks_failing_field :: proc(t: ^testing.T) {
	track := track_begin()
	context.allocator = mem_tracking(&track)
	defer track_end(t, &track)
	expect_counterexample(t, proc(s: ^qc.Source) -> bool {
		o := qc.arbitrary(s, Order)
		return len(o.tags) < 2
	}, "draw 1: Order{id = 0, color = \"Red\", paid = false, tags = [\"\", \"\"], totals = [0, 0], code = 0}\n")
}

@(test)
test_arbitrary_enum_uses_declared_values :: proc(t: ^testing.T) {
	track := track_begin()
	context.allocator = mem_tracking(&track)
	defer track_end(t, &track)
	expect_passes(t, proc(s: ^qc.Source) -> bool {
		c := qc.arbitrary(s, Color)
		return c == .Red || c == .Green || c == .Blue
	}, {cases = 300})
}

@(test)
test_arbitrary_strings_are_valid_utf8 :: proc(t: ^testing.T) {
	track := track_begin()
	context.allocator = mem_tracking(&track)
	defer track_end(t, &track)
	expect_passes(t, proc(s: ^qc.Source) -> bool {
		str := qc.arbitrary(s, string)
		cs := qc.arbitrary(s, cstring)
		for c in transmute([]u8)string(cs) {
			if c == 0 {
				return false
			}
		}
		return utf8.valid_string(str) && utf8.rune_count_in_string(str) <= qc.ARBITRARY_MAX_LEN
	}, {cases = 500})
}

@(test)
test_arbitrary_small_floats_are_finite :: proc(t: ^testing.T) {
	track := track_begin()
	context.allocator = mem_tracking(&track)
	defer track_end(t, &track)
	expect_passes(t, proc(s: ^qc.Source) -> bool {
		a := qc.arbitrary(s, f32)
		b := qc.arbitrary(s, f16)
		return !math.is_inf(f64(a)) && !math.is_nan(f64(a)) && !math.is_inf(f64(b)) && !math.is_nan(f64(b))
	}, {cases = 1000})
}

Shape :: union {
	int,
	string,
	Point,
}

@(test)
test_arbitrary_union_covers_nil_and_variants :: proc(t: ^testing.T) {
	track := track_begin()
	context.allocator = mem_tracking(&track)
	defer track_end(t, &track)
	seen: Seen
	expect_passes(t, proc(s: ^qc.Source) -> bool {
		seen := (^Seen)(s.user_data)
		switch v in qc.arbitrary(s, Shape) {
		case nil:
			seen.falses += 1
		case int:
			seen.trues += 1
		case string:
			seen.special += 1
			return utf8.valid_string(v)
		case Point:
			seen.lo += 1
		}
		return true
	}, {cases = 400, user_data = &seen})
	testing.expect(t, seen.falses > 0 && seen.trues > 0 && seen.special > 0 && seen.lo > 0, "a union variant never came up")
	expect_counterexample(t, proc(s: ^qc.Source) -> bool {
		_, is_point := qc.arbitrary(s, Shape).(Point)
		return !is_point
	}, "draw 1: Point{x = 0, y = 0}\n")
}

@(test)
test_arbitrary_maybe_shrinks_to_nil :: proc(t: ^testing.T) {
	track := track_begin()
	context.allocator = mem_tracking(&track)
	defer track_end(t, &track)
	expect_counterexample(t, proc(s: ^qc.Source) -> bool {
		_ = qc.arbitrary(s, Maybe(int))
		return false
	}, "draw 1: nil\n")
}

Flag :: enum {
	A,
	B,
	C,
}

@(test)
test_arbitrary_bit_set_and_enumerated_array :: proc(t: ^testing.T) {
	track := track_begin()
	context.allocator = mem_tracking(&track)
	defer track_end(t, &track)
	expect_passes(t, proc(s: ^qc.Source) -> bool {
		flags := qc.arbitrary(s, bit_set[Flag])
		counts := qc.arbitrary(s, [Flag]u8)
		_ = counts
		return transmute(u8)flags < 8
	}, {cases = 300})
	expect_counterexample(t, proc(s: ^qc.Source) -> bool {
		flags := qc.arbitrary(s, bit_set[Flag])
		return .C not_in flags
	}, "draw 1: bit_set[Flag]{C}\n")
}

Tree :: struct {
	value:    int,
	children: []Tree,
}

@(test)
test_arbitrary_recursive_type_terminates :: proc(t: ^testing.T) {
	track := track_begin()
	context.allocator = mem_tracking(&track)
	defer track_end(t, &track)
	depth :: proc(tree: Tree) -> int {
		d := 0
		for child in tree.children {
			d = max(d, depth(child))
		}
		return d + 1
	}
	expect_passes(t, proc(s: ^qc.Source) -> bool {
		return depth(qc.arbitrary(s, Tree)) <= qc.ARBITRARY_MAX_DEPTH + 1
	}, {cases = 50})
}

Linked :: struct {
	value: int,
	next:  ^Linked,
}

@(test)
test_arbitrary_rejects_unsupported_types :: proc(t: ^testing.T) {
	track := track_begin()
	context.allocator = mem_tracking(&track)
	defer track_end(t, &track)
	expect_run_error(t, proc(s: ^qc.Source) -> bool {
		_ = qc.arbitrary(s, Linked)
		return true
	}, qc.Generator_Error.Unsupported_Type)
	expect_run_error(t, proc(s: ^qc.Source) -> bool {
		_ = qc.arbitrary(s, map[string]int)
		return true
	}, qc.Generator_Error.Unsupported_Type)
}

@(test)
test_arbitrary_integers_cover_full_width :: proc(t: ^testing.T) {
	track := track_begin()
	context.allocator = mem_tracking(&track)
	defer track_end(t, &track)
	seen := Seen{max(i64), min(i64), 0, 0, 0}
	expect_passes(t, proc(s: ^qc.Source) -> bool {
		seen := (^Seen)(s.user_data)
		v := i64(qc.arbitrary(s, i16))
		seen.lo = min(seen.lo, v)
		seen.hi = max(seen.hi, v)
		big := qc.arbitrary(s, u128)
		return big <= u128(max(u64))
	}, {cases = 2000, user_data = &seen})
	testing.expect_value(t, seen.lo, i64(min(i16)))
	testing.expect_value(t, seen.hi, i64(max(i16)))
}
