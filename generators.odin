package quickcheck

import "base:intrinsics"
import "core:math"
import "core:strings"
import "core:unicode/utf8"

// MAX_SAFE_INTEGER is the largest integer that every f64 between -it and it can represent exactly.
@(private)
MAX_SAFE_INTEGER :: 1 << 53

/*
ASCII_PRINTABLE holds the 95 printable ASCII characters, ordered so that
strings shrink toward lowercase letters, then capitals, digits and symbols.
*/
ASCII_PRINTABLE :: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 !\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~"

/*
boolean draws `true` or `false`. It shrinks toward `false`.
*/
boolean :: proc(s: ^Source) -> bool {
	enter(s)
	return leave(s, draw_choice(s, 1) == 1)
}

// i64_between draws from [lo, hi], shrinking toward the value closest to zero. Callers check lo <= hi.
@(private)
i64_between :: proc(s: ^Source, lo, hi: i64) -> i64 {
	switch {
	case lo >= 0:
		return i64(u64(lo) + draw_choice(s, u64(hi) - u64(lo)))
	case hi <= 0:
		return i64(u64(hi) - draw_choice(s, u64(hi) - u64(lo)))
	}
	if draw_choice(s, 1) == 1 {
		return i64(0 - draw_choice(s, 0 - u64(lo)))
	}
	return i64(draw_choice(s, u64(hi)))
}

/*
integer_range draws an integer in [lo, hi]. It shrinks toward the value in
the range that is closest to zero, so `integer_range(s, 5, 9)` shrinks to 5
and `integer_range(s, -9, 9)` shrinks to 0.

Inputs:
- s: the source to draw from.
- lo, hi: the inclusive bounds; any integer type of 64 bits or fewer.

Returns: the value, or `lo` with `.Invalid_Range` recorded when `lo > hi`.
*/
integer_range :: proc(s: ^Source, lo, hi: $T) -> T where intrinsics.type_is_integer(T) && size_of(T) <= 8 {
	enter(s)
	if lo > hi {
		set_error(s, Generator_Error.Invalid_Range)
		return leave(s, lo)
	}
	when intrinsics.type_is_unsigned(T) {
		v := T(u64(lo) + draw_choice(s, u64(hi) - u64(lo)))
	} else {
		v := T(i64_between(s, i64(lo), i64(hi)))
	}
	return leave(s, v)
}

/*
integer draws any value of the integer type `T`, from `min(T)` to `max(T)`.
It shrinks toward zero.

Example:
	b := qc.integer(s, u8)
	n := qc.integer(s, i64)
*/
integer :: proc(s: ^Source, $T: typeid) -> T where intrinsics.type_is_integer(T) && size_of(T) <= 8 {
	return integer_range(s, min(T), max(T))
}

/*
int_range draws an `int` in [lo, hi]. It is integer_range for the common
case, and shrinks toward the value closest to zero.
*/
int_range :: proc(s: ^Source, lo, hi: int) -> int {
	return integer_range(s, lo, hi)
}

// float_between draws from [lo, hi]; callers check that both bounds are finite and lo <= hi.
@(private)
float_between :: proc(s: ^Source, lo, hi: f64) -> f64 {
	if lo == hi {
		return lo
	}
	// Most fresh floats have a fraction, but shrinking prefers whole numbers.
	fractional := draw_choice(s, 1, weighted = true, p = 0.8) == 1
	if !fractional {
		ilo := max(math.ceil(lo), -MAX_SAFE_INTEGER)
		ihi := min(math.floor(hi), MAX_SAFE_INTEGER)
		if ilo <= ihi {
			return f64(i64_between(s, i64(ilo), i64(ihi)))
		}
	}
	frac := f64(draw_choice(s, MAX_SAFE_INTEGER - 1)) * (1.0 / MAX_SAFE_INTEGER)
	v: f64
	switch {
	case lo >= 0:
		v = lo + frac * (hi - lo)
	case hi <= 0:
		v = hi - frac * (hi - lo)
	case draw_choice(s, 1) == 1:
		v = frac * lo
	case:
		v = frac * hi
	}
	return clamp(v, lo, hi)
}

/*
float_range draws a finite `f64` in [lo, hi]. It shrinks toward whole numbers
and toward the value in the range closest to zero.

Returns: the value, or 0 with `.Invalid_Range` recorded when a bound is NaN
or infinite, or when `lo > hi`.
*/
float_range :: proc(s: ^Source, lo, hi: f64) -> f64 {
	enter(s)
	if math.is_nan(lo) || math.is_nan(hi) || math.is_inf(lo) || math.is_inf(hi) || lo > hi {
		set_error(s, Generator_Error.Invalid_Range)
		return leave(s, f64(0))
	}
	return leave(s, float_between(s, lo, hi))
}

// float_unbounded draws any f64 according to the flags; see float_any.
@(private)
float_unbounded :: proc(s: ^Source, allow_nan, allow_inf: bool) -> f64 {
	SPECIALS := [?]f64 {
		0,
		-0.0,
		1,
		-1,
		4.9406564584124654e-324, // smallest subnormal
		2.2250738585072014e-308, // smallest normal
		math.F64_EPSILON,
		math.F64_MAX,
		-math.F64_MAX,
	}
	switch draw_choice(s, 3) {
	case 0:
		return float_between(s, -1e6, 1e6)
	case 1:
		return float_between(s, -math.F64_MAX, math.F64_MAX)
	case 2:
		extra := 0
		if allow_inf {
			extra += 2
		}
		if allow_nan {
			extra += 1
		}
		i := int(draw_choice(s, u64(len(SPECIALS) + extra - 1)))
		if i < len(SPECIALS) {
			return SPECIALS[i]
		}
		i -= len(SPECIALS)
		if allow_inf {
			if i == 0 {
				return math.inf_f64(1)
			}
			if i == 1 {
				return math.inf_f64(-1)
			}
		}
		return math.nan_f64()
	}
	raw := draw_choice(s, max(u64))
	f := transmute(f64)raw
	if (math.is_nan(f) && !allow_nan) || (math.is_inf(f) && !allow_inf) {
		// Clearing the top exponent bit always yields a finite value.
		f = transmute(f64)(raw & ~(u64(1) << 62))
	}
	return f
}

/*
float_any draws any `f64`: small and huge values, subnormals, both zeros and
raw bit patterns. NaN and the infinities only appear when allowed. It shrinks
toward 0.
*/
float_any :: proc(s: ^Source, allow_nan := false, allow_inf := false) -> f64 {
	enter(s)
	return leave(s, float_unbounded(s, allow_nan, allow_inf))
}

/*
rune_range draws a code point in [lo, hi], skipping UTF-16 surrogates. It
shrinks toward `lo`.

Returns: the rune, or `lo` with `.Invalid_Range` recorded when `lo > hi`,
`lo < 0`, `hi > utf8.MAX_RUNE` or the range holds only surrogates.
*/
rune_range :: proc(s: ^Source, lo, hi: rune) -> rune {
	enter(s)
	if lo > hi || lo < 0 || hi > utf8.MAX_RUNE || (lo >= 0xD800 && hi <= 0xDFFF) {
		set_error(s, Generator_Error.Invalid_Range)
		return leave(s, lo)
	}
	r := rune(u64(lo) + draw_choice(s, u64(hi - lo)))
	if r < 0xD800 || r > 0xDFFF {
		return leave(s, r)
	}
	// Move a surrogate past the gap, or below it when the gap ends the range.
	if hi > 0xDFFF {
		return leave(s, min(hi, r + 0x800))
	}
	return leave(s, rune(0xD7FF))
}

// any_rune draws any scalar value, shrinking toward ASCII_PRINTABLE.
@(private)
any_rune :: proc(s: ^Source) -> rune {
	SCALARS :: utf8.MAX_RUNE + 1 - 0x800
	c := draw_choice(s, u64(len(ASCII_PRINTABLE) + SCALARS - 1))
	if c < len(ASCII_PRINTABLE) {
		ascii := ASCII_PRINTABLE
		return rune(ascii[c])
	}
	r := rune(c - len(ASCII_PRINTABLE))
	if r >= 0xD800 {
		r += 0x800
	}
	return r
}

// Length tracks how many elements a collection generator has produced.
@(private)
Length :: struct {
	min, max, count: int,
	p:               f64,
}

// length_init picks the continue probability so that collections average a few elements past `min`.
@(private)
length_init :: proc(min_len, max_len: int) -> Length {
	average := f64(clamp(max_len - min_len, 0, 8))
	return {min = min_len, max = max_len, p = average / (average + 1)}
}

/*
length_more decides whether a collection gets another element. Past the
minimum, each element costs a 0/1 choice, so deleting a choice pair shrinks
the collection by one element.
*/
@(private)
length_more :: proc(s: ^Source, l: ^Length) -> bool {
	if failed(s) || l.count >= l.max {
		return false
	}
	if l.count < l.min || draw_choice(s, 1, weighted = true, p = l.p) == 1 {
		l.count += 1
		return true
	}
	return false
}

// build_string draws runes with `pick` into a string in the case arena.
@(private)
build_string :: proc(s: ^Source, min_len, max_len: int, pick: proc(s: ^Source, data: string) -> rune, data: string) -> string {
	if min_len < 0 || max_len < min_len {
		set_error(s, Generator_Error.Invalid_Length)
		return ""
	}
	b, err := strings.builder_make(0, min_len, s.allocator)
	if err != nil {
		set_error(s, err)
		return ""
	}
	l := length_init(min_len, max_len)
	for length_more(s, &l) {
		if _, werr := strings.write_rune(&b, pick(s, data)); werr != nil {
			set_error(s, Generator_Error.Invalid_Length)
		}
	}
	return strings.to_string(b)
}

/*
string_of draws a string of `min_len` to `max_len` runes taken from
`alphabet`. It shrinks toward shorter strings made of the first rune of the
alphabet. The string lives in the case arena.

Example:
	hex := qc.string_of(s, "0123456789abcdef", 1, 16)

Returns: the string, or "" with `.Empty_Alphabet` or `.Invalid_Length`
recorded when an argument is malformed.
*/
string_of :: proc(s: ^Source, alphabet: string, min_len, max_len: int) -> string {
	enter(s)
	if len(alphabet) == 0 || !utf8.valid_string(alphabet) {
		set_error(s, Generator_Error.Empty_Alphabet)
		return leave(s, "")
	}
	pick :: proc(s: ^Source, alphabet: string) -> rune {
		n := utf8.rune_count_in_string(alphabet)
		i := int(draw_choice(s, u64(n - 1)))
		for r in alphabet {
			if i == 0 {
				return r
			}
			i -= 1
		}
		return utf8.RUNE_ERROR
	}
	return leave(s, build_string(s, min_len, max_len, pick, alphabet))
}

/*
ascii_string draws a string of printable ASCII characters, between `min_len`
and `max_len` long. It shrinks toward shorter strings of `a`.
*/
ascii_string :: proc(s: ^Source, min_len, max_len: int) -> string {
	enter(s)
	pick :: proc(s: ^Source, alphabet: string) -> rune {
		return rune(alphabet[draw_choice(s, u64(len(alphabet) - 1))])
	}
	return leave(s, build_string(s, min_len, max_len, pick, ASCII_PRINTABLE))
}

/*
utf8_string draws a valid UTF-8 string of `min_len` to `max_len` code points,
drawn from all of Unicode except surrogates. It shrinks toward shorter ASCII
strings.
*/
utf8_string :: proc(s: ^Source, min_len, max_len: int) -> string {
	enter(s)
	pick :: proc(s: ^Source, _: string) -> rune {
		return any_rune(s)
	}
	return leave(s, build_string(s, min_len, max_len, pick, ""))
}
