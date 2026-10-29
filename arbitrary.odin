package quickcheck

import "base:intrinsics"
import "base:runtime"
import "core:math"
import "core:mem"
import "core:reflect"
import "core:strings"

// ARBITRARY_MAX_LEN is the longest string or slice that arbitrary builds at the top level.
ARBITRARY_MAX_LEN :: 8

// ARBITRARY_MAX_DEPTH is how deep arbitrary nests slices before it makes them empty, so recursive types stay finite.
ARBITRARY_MAX_DEPTH :: 4

/*
arbitrary draws a value of any plain data type `T` by reflection: integers,
floats, booleans, runes, strings, enums, bit sets, fixed and enumerated
arrays, slices, structs and unions of those, nested to any depth.

Every field shrinks toward its zero value, strings and slices shrink toward
empty, enums toward their first member and unions toward their first variant.
Strings and slices hold at most ARBITRARY_MAX_LEN elements and live in the
case arena.

Example:
	Order :: struct {
		id:    u32,
		items: []string,
		paid:  bool,
	}
	order := qc.arbitrary(s, Order)

Returns: the value. When `T` contains a pointer, map, procedure, dynamic
array or other type that arbitrary can't build, the unsupported part stays
zero and `.Unsupported_Type` is recorded, which stops the run.
*/
arbitrary :: proc(s: ^Source, $T: typeid) -> T {
	enter(s)
	value: T
	arbitrary_fill(s, &value, type_info_of(T), 0)
	return leave(s, value)
}

// arbitrary_fill writes a drawn value of type `ti` into the zeroed memory at `ptr`.
@(private)
arbitrary_fill :: proc(s: ^Source, ptr: rawptr, ti: ^runtime.Type_Info, depth: int) {
	if failed(s) {
		return
	}
	base := runtime.type_info_base(ti)
	#partial switch info in base.variant {
	case runtime.Type_Info_Integer:
		write_integer(ptr, base.size, draw_integer_bits(s, base.size, info.signed), info.signed, swapped(info.endianness))
	case runtime.Type_Info_Rune:
		(^rune)(ptr)^ = any_rune(s)
	case runtime.Type_Info_Boolean:
		write_integer(ptr, base.size, draw_choice(s, 1))
	case runtime.Type_Info_Float:
		v := float_unbounded(s, false, false)
		// Write the bits through write_integer, which byte-swaps them for
		// floats such as f32be whose byte order isn't the platform's.
		bits: u64
		switch base.size {
		case 2:
			bits = u64(transmute(u16)f16(clamp(v, -65504, 65504)))
		case 4:
			bits = u64(transmute(u32)f32(clamp(v, -f64(math.F32_MAX), f64(math.F32_MAX))))
		case 8:
			bits = transmute(u64)v
		case:
			set_error(s, Generator_Error.Unsupported_Type)
			return
		}
		write_integer(ptr, base.size, bits, false, swapped(info.endianness))
	case runtime.Type_Info_String:
		if info.encoding != .UTF_8 {
			set_error(s, Generator_Error.Unsupported_Type)
			return
		}
		max_len := depth < ARBITRARY_MAX_DEPTH ? ARBITRARY_MAX_LEN : 0
		if info.is_cstring {
			// A cstring can't hold NUL, so draw printable ASCII.
			ascii :: proc(s: ^Source, alphabet: string) -> rune {
				return rune(alphabet[draw_choice(s, u64(len(alphabet) - 1))])
			}
			str := build_string(s, 0, max_len, ascii, ASCII_PRINTABLE)
			cs, err := strings.clone_to_cstring(str, s.allocator)
			if err != nil {
				set_error(s, err)
				return
			}
			(^cstring)(ptr)^ = cs
			return
		}
		pick :: proc(s: ^Source, _: string) -> rune {
			return any_rune(s)
		}
		(^string)(ptr)^ = build_string(s, 0, max_len, pick, "")
	case runtime.Type_Info_Enum:
		if len(info.values) == 0 {
			return
		}
		i := draw_choice(s, u64(len(info.values) - 1))
		write_integer(ptr, base.size, u64(info.values[i]), swap = integer_swapped(info.base))
	case runtime.Type_Info_Bit_Set:
		if info.upper < info.lower {
			return
		}
		set: u64
		for i in 0 ..= info.upper - info.lower {
			if i < 64 && draw_choice(s, 1) == 1 {
				set |= u64(1) << u64(i)
			}
		}
		write_integer(ptr, base.size, set, swap = integer_swapped(info.underlying))
	case runtime.Type_Info_Array:
		for i in 0 ..< info.count {
			arbitrary_fill(s, rawptr(uintptr(ptr) + uintptr(i * info.elem_size)), info.elem, depth)
		}
	case runtime.Type_Info_Enumerated_Array:
		for i in 0 ..< info.count {
			arbitrary_fill(s, rawptr(uintptr(ptr) + uintptr(i * info.elem_size)), info.elem, depth)
		}
	case runtime.Type_Info_Slice:
		max_len := depth < ARBITRARY_MAX_DEPTH ? ARBITRARY_MAX_LEN : 0
		if max_len == 0 || info.elem_size == 0 {
			return
		}
		// Reserve room for the longest slice so that each element's choices
		// follow its length flag, which lets the shrinker drop both at once.
		data, err := mem.alloc(max_len * info.elem_size, info.elem.align, s.allocator)
		if err != nil {
			set_error(s, err)
			return
		}
		l := length_init(0, max_len)
		for length_more(s, &l) {
			arbitrary_fill(s, rawptr(uintptr(data) + uintptr((l.count - 1) * info.elem_size)), info.elem, depth + 1)
		}
		if l.count > 0 {
			(^runtime.Raw_Slice)(ptr)^ = {data, l.count}
		}
	case runtime.Type_Info_Struct:
		count := int(info.field_count)
		if .raw_union in info.flags {
			count = min(count, 1)
		}
		for i in 0 ..< count {
			arbitrary_fill(s, rawptr(uintptr(ptr) + info.offsets[i]), info.types[i], depth)
		}
	case runtime.Type_Info_Union:
		if len(info.variants) == 0 || reflect.type_info_union_is_pure_maybe(info) {
			set_error(s, Generator_Error.Unsupported_Type)
			return
		}
		n := len(info.variants)
		if info.no_nil {
			i := int(draw_choice(s, u64(n - 1)))
			arbitrary_fill(s, ptr, info.variants[i], depth)
			reflect.set_union_variant_raw_tag(any{ptr, ti.id}, i64(i))
			return
		}
		tag := int(draw_choice(s, u64(n)))
		if tag == 0 {
			return
		}
		arbitrary_fill(s, ptr, info.variants[tag - 1], depth)
		reflect.set_union_variant_raw_tag(any{ptr, ti.id}, i64(tag))
	case:
		set_error(s, Generator_Error.Unsupported_Type)
	}
}

// draw_integer_bits draws a full-range integer of `size` bytes, returned as its two's complement bits.
@(private)
draw_integer_bits :: proc(s: ^Source, size: int, signed: bool) -> u64 {
	width := uint(min(size, 8) * 8)
	if signed {
		hi := i64(max(u64) >> (65 - width))
		return u64(i64_between(s, -hi - 1, hi))
	}
	return draw_choice(s, max(u64) >> (64 - width))
}

// swapped reports whether a value with byte order `e` is stored in the reverse of the platform's byte order.
@(private)
swapped :: proc(e: runtime.Platform_Endianness) -> bool {
	switch e {
	case .Platform:
		return false
	case .Little:
		return ODIN_ENDIAN != .Little
	case .Big:
		return ODIN_ENDIAN != .Big
	}
	return false
}

// integer_swapped reports whether the integer type `ti` is stored in the reverse of the platform's byte order.
@(private)
integer_swapped :: proc(ti: ^runtime.Type_Info) -> bool {
	if ti == nil {
		return false
	}
	if info, ok := runtime.type_info_base(ti).variant.(runtime.Type_Info_Integer); ok {
		return swapped(info.endianness)
	}
	return false
}

/*
write_integer stores the low `size` bytes of `v` at `ptr`, sign-extending
signed 128-bit integers. When `swap` is true it stores the bytes in reverse
order, for types such as u16be on a little-endian platform.
*/
@(private)
write_integer :: proc(ptr: rawptr, size: int, v: u64, signed := false, swap := false) {
	switch size {
	case 1:
		(^u8)(ptr)^ = u8(v)
	case 2:
		x := u16(v)
		(^u16)(ptr)^ = swap ? intrinsics.byte_swap(x) : x
	case 4:
		x := u32(v)
		(^u32)(ptr)^ = swap ? intrinsics.byte_swap(x) : x
	case 8:
		(^u64)(ptr)^ = swap ? intrinsics.byte_swap(v) : v
	case 16:
		x := signed ? u128(i128(i64(v))) : u128(v)
		(^u128)(ptr)^ = swap ? intrinsics.byte_swap(x) : x
	}
}
