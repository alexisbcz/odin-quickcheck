package quickcheck

/*
slice_of draws a slice of `min_len` to `max_len` elements, each drawn with
`gen`. It shrinks by removing elements and by shrinking each element. The
slice lives in the case arena.

Example:
	gen_digit :: proc(s: ^qc.Source) -> int { return qc.int_range(s, 0, 9) }
	digits := qc.slice_of(s, gen_digit, 1, 10)

Returns: the slice, or `nil` with `.Invalid_Length` recorded when
`min_len < 0` or `max_len < min_len`.
*/
slice_of :: proc(s: ^Source, gen: proc(s: ^Source) -> $T, min_len, max_len: int) -> []T {
	enter(s)
	zero: []T
	if min_len < 0 || max_len < min_len {
		set_error(s, Generator_Error.Invalid_Length)
		return leave(s, zero)
	}
	out, err := make([dynamic]T, 0, min_len, s.allocator)
	if err != nil {
		set_error(s, err)
		return leave(s, zero)
	}
	l := length_init(min_len, max_len)
	for length_more(s, &l) {
		v := gen(s)
		if _, aerr := append(&out, v); aerr != nil {
			set_error(s, aerr)
			break
		}
	}
	return leave(s, out[:])
}

/*
element_of draws one element of `items`. It shrinks toward the first element,
so put the simplest item first.

Returns: the element, or the zero value with `.Empty_Choices` recorded when
`items` is empty.
*/
element_of :: proc(s: ^Source, items: []$T) -> T {
	enter(s)
	zero: T
	if len(items) == 0 {
		set_error(s, Generator_Error.Empty_Choices)
		return leave(s, zero)
	}
	return leave(s, items[draw_choice(s, u64(len(items) - 1))])
}

/*
one_of picks one of `gens` with equal odds and returns what it draws. It
shrinks toward the first generator, then shrinks the value that generator
drew.

Example:
	small :: proc(s: ^qc.Source) -> int { return qc.int_range(s, 0, 9) }
	huge :: proc(s: ^qc.Source) -> int { return qc.int_range(s, 1_000_000, 2_000_000) }
	n := qc.one_of(s, int, small, huge)

Returns: the value, or the zero value with `.Empty_Choices` recorded when
`gens` is empty or the picked generator is nil.
*/
one_of :: proc(s: ^Source, $T: typeid, gens: ..proc(s: ^Source) -> T) -> T {
	enter(s)
	zero: T
	if len(gens) == 0 {
		set_error(s, Generator_Error.Empty_Choices)
		return leave(s, zero)
	}
	gen := gens[draw_choice(s, u64(len(gens) - 1))]
	if gen == nil {
		set_error(s, Generator_Error.Empty_Choices)
		return leave(s, zero)
	}
	return leave(s, gen(s))
}

// Weighted pairs a generator with its relative weight for frequency.
Weighted :: struct($T: typeid) {
	// weight is the relative chance of picking gen. It must not be negative.
	weight: int,
	// gen draws the value when this entry is picked.
	gen:    proc(s: ^Source) -> T,
}

/*
frequency picks one entry with odds proportional to its weight and returns
what its generator draws. It shrinks toward the first entry with a positive
weight.

Example:
	n := qc.frequency(s, int, qc.Weighted(int){9, small}, qc.Weighted(int){1, huge})

Returns: the value, or the zero value with `.Empty_Choices` or
`.Invalid_Weights` recorded when there's nothing to pick, a weight is
negative or the weights sum to zero or overflow.
*/
frequency :: proc(s: ^Source, $T: typeid, entries: ..Weighted(T)) -> T {
	enter(s)
	zero: T
	if len(entries) == 0 {
		set_error(s, Generator_Error.Empty_Choices)
		return leave(s, zero)
	}
	total: u64
	for e in entries {
		if e.weight < 0 || e.gen == nil {
			set_error(s, Generator_Error.Invalid_Weights)
			return leave(s, zero)
		}
		next := total + u64(e.weight)
		if next < total {
			set_error(s, Generator_Error.Invalid_Weights)
			return leave(s, zero)
		}
		total = next
	}
	if total == 0 {
		set_error(s, Generator_Error.Invalid_Weights)
		return leave(s, zero)
	}
	pick := draw_choice(s, total - 1)
	for e in entries {
		w := u64(e.weight)
		if pick < w {
			return leave(s, e.gen(s))
		}
		pick -= w
	}
	// Unreachable: pick < total by construction.
	return leave(s, zero)
}

/*
mapped draws a value with `gen` and returns `f` applied to it. Odin reserves
the word `map`, hence the name. The result shrinks as the input does.

Example:
	even := qc.mapped(s, gen_digit, proc(n: int) -> int { return n * 2 })
*/
mapped :: proc(s: ^Source, gen: proc(s: ^Source) -> $A, f: proc(a: A) -> $B) -> B {
	enter(s)
	return leave(s, f(gen(s)))
}

/*
filtered draws values with `gen` until one satisfies `pred`, trying at most
`max_tries` times. Shrunk values still satisfy `pred`.

Returns:
- value: the first value that passed, or the last one tried.
- ok: false when no value passed. The runner then discards the case, so the
  property should return right away.

Prefer a generator that builds valid values directly; a filter that rejects
most values makes the run give up.
*/
filtered :: proc(s: ^Source, gen: proc(s: ^Source) -> $T, pred: proc(v: T) -> bool, max_tries := 100) -> (value: T, ok: bool) {
	enter(s)
	for _ in 0 ..< max(max_tries, 1) {
		value = gen(s)
		if failed(s) {
			break
		}
		if pred(value) {
			return leave(s, value), true
		}
	}
	s.rejected = true
	return leave(s, value), false
}

/*
maybe_of draws `nil` or a value from `gen`, with even odds for a fresh case.
It shrinks toward `nil`.
*/
maybe_of :: proc(s: ^Source, gen: proc(s: ^Source) -> $T) -> Maybe(T) {
	enter(s)
	if draw_choice(s, 1) == 0 {
		return leave(s, Maybe(T)(nil))
	}
	return leave(s, Maybe(T)(gen(s)))
}
