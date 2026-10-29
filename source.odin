package quickcheck

import "base:runtime"
import "core:fmt"
import "core:math/bits"
import "core:strings"

/*
Source is the stream of choices that generators draw from. The runner creates
one for each run and hands it to the property; never create one yourself.

Read only `allocator` and `user_data`. Every other field is internal state of
the runner and may change between releases.

A Source is safe to use from one thread at a time.
*/
Source :: struct {
	// allocator is the per-case arena. Every value a generator returns lives in it until the case ends.
	allocator:   runtime.Allocator,
	// user_data is Config.user_data, passed through unchanged.
	user_data:   rawptr,

	// Internal: the choices made so far in this case.
	choices:     [dynamic]u64,
	// Internal: the kind of each choice, used by the shrinker to lower related choices together.
	kinds:       [dynamic]u64,
	// Internal: choices to replay before generating or zero-filling.
	prefix:      []u64,
	// Internal: position in prefix.
	index:       int,
	// Internal: whether to draw random choices past the prefix.
	generating:  bool,
	// Internal: random state for this case.
	rng:         Rng,
	// Internal: how many choices one case may make.
	max_choices: int,
	// Internal: set when the case was discarded by assume or filtered.
	rejected:    bool,
	// Internal: set when the case ran past max_choices.
	overrun:     bool,
	// Internal: the first generator error of this case.
	err:         Error,
	// Internal: nesting depth of generator calls, used to log top-level draws only.
	depth:       int,
	// Internal: whether to log draws and notes into log.
	recording:   bool,
	// Internal: the number of top-level draws logged so far.
	draws:       int,
	// Internal: the counterexample text being built.
	log:         strings.Builder,
}

/*
Rng is the xoshiro256** generator the runner seeds for every case. It is
internal, but exported so that Source can embed it.
*/
Rng :: struct {
	state: [4]u64,
}

@(private)
splitmix64 :: proc(x: ^u64) -> u64 {
	x^ += 0x9E3779B97F4A7C15
	z := x^
	z = (z ~ (z >> 30)) * 0xBF58476D1CE4E5B9
	z = (z ~ (z >> 27)) * 0x94D049BB133111EB
	return z ~ (z >> 31)
}

@(private)
rng_init :: proc(r: ^Rng, seed: u64) {
	x := seed
	for i in 0 ..< 4 {
		r.state[i] = splitmix64(&x)
	}
}

@(private)
rng_next :: proc(r: ^Rng) -> u64 {
	s := &r.state
	result := bits.rotate_left64(s[1] * 5, 7) * 9
	t := s[1] << 17
	s[2] ~= s[0]
	s[3] ~= s[1]
	s[1] ~= s[2]
	s[0] ~= s[3]
	s[2] ~= t
	s[3] = bits.rotate_left64(s[3], 45)
	return result
}

// rng_below returns a uniform value in [0, bound], without modulo bias.
@(private)
rng_below :: proc(r: ^Rng, bound: u64) -> u64 {
	if bound == max(u64) {
		return rng_next(r)
	}
	n := bound + 1
	threshold := (0 - n) % n
	for {
		x := rng_next(r)
		if x >= threshold {
			return x % n
		}
	}
}

// rng_float returns a uniform value in [0, 1).
@(private)
rng_float :: proc(r: ^Rng) -> f64 {
	return f64(rng_next(r) >> 11) * (1.0 / (1 << 53))
}

// case_seed derives the seed of case number `n` from the run seed.
@(private)
case_seed :: proc(seed: u64, n: int) -> u64 {
	x := seed ~ (u64(n) * 0xD1B54A32D192ED03)
	return splitmix64(&x)
}

// failed reports whether the case can no longer produce a meaningful result.
@(private)
failed :: #force_inline proc(s: ^Source) -> bool {
	return s.err != nil || s.overrun
}

// set_error records the first generator error of the case.
@(private)
set_error :: proc(s: ^Source, err: Error) {
	if s.err == nil {
		s.err = err
	}
}

/*
generate_choice picks a fresh value in [0, bound]. Large bounds are biased
toward the edges and toward small numbers, because that is where bugs live.
*/
@(private)
generate_choice :: proc(r: ^Rng, bound: u64) -> u64 {
	if bound <= 1 {
		return rng_below(r, bound)
	}
	roll := rng_next(r) % 16
	switch {
	case roll == 0:
		return 0
	case roll == 1:
		return bound
	case roll < 8:
		width := 1 + rng_below(r, 63)
		x := rng_next(r) & ((u64(1) << width) - 1)
		if x <= bound {
			return x
		}
		return x % (bound + 1)
	}
	return rng_below(r, bound)
}

/*
draw_choice makes one choice in [0, bound] and records it. Smaller choices
are simpler: shrinking only ever lowers or deletes them. When `weighted` is
true and the choice is fresh, 1 comes up with probability `p` (bound is 1).
*/
@(private)
draw_choice :: proc(s: ^Source, bound: u64, weighted := false, p := 0.5) -> u64 {
	if failed(s) {
		return 0
	}
	if len(s.choices) >= s.max_choices {
		s.overrun = true
		return 0
	}
	v: u64
	switch {
	case s.index < len(s.prefix):
		v = min(s.prefix[s.index], bound)
	case !s.generating:
		v = 0
	case weighted:
		v = rng_float(&s.rng) < p ? 1 : 0
	case:
		v = generate_choice(&s.rng, bound)
	}
	s.index += 1
	if _, err := append(&s.choices, v); err != nil {
		set_error(s, err)
		return 0
	}
	if _, err := append(&s.kinds, weighted ? WEIGHTED_KIND : bound); err != nil {
		set_error(s, err)
		return 0
	}
	return v
}

// WEIGHTED_KIND marks length flags and other weighted coin flips in Source.kinds.
@(private)
WEIGHTED_KIND :: max(u64) - 1

// enter marks the start of a public generator call.
@(private)
enter :: #force_inline proc(s: ^Source) {
	s.depth += 1
}

// leave marks the end of a public generator call and logs top-level values.
@(private)
leave :: proc(s: ^Source, value: $T) -> T {
	s.depth -= 1
	if s.depth == 0 && s.recording {
		s.draws += 1
		when T == string {
			fmt.sbprintf(&s.log, "draw %d: %q\n", s.draws, value)
		} else {
			fmt.sbprintf(&s.log, "draw %d: %v\n", s.draws, value)
		}
	}
	return value
}

/*
draw calls `gen` and reports its result as a single value in the
counterexample. Without draw, a counterexample lists every top-level
generator call that `gen` makes on its own.

Example:
	Point :: struct { x, y: int }
	gen_point :: proc(s: ^qc.Source) -> Point {
		return {qc.int_range(s, -9, 9), qc.int_range(s, -9, 9)}
	}
	p := qc.draw(s, gen_point) // reported as "draw 1: Point{x = 0, y = 3}"
*/
draw :: proc(s: ^Source, gen: proc(s: ^Source) -> $T) -> T {
	enter(s)
	return leave(s, gen(s))
}

/*
note adds a line to the counterexample report. It formats its arguments like
`fmt.println`, and only does work on the final replay of the minimal failing
case, so it costs nothing while the runner searches.
*/
note :: proc(s: ^Source, args: ..any) {
	if s.recording {
		fmt.sbprintln(&s.log, ..args)
	}
}

/*
assume discards the current case when `cond` is false. The runner doesn't
count a discarded case as passing or failing, and gives up when it discards
more than Config.max_discards.

Returns `cond`, so a property can bail out early:

	if !qc.assume(s, d != 0) {
		return true
	}
*/
assume :: proc(s: ^Source, cond: bool) -> bool {
	if !cond {
		s.rejected = true
	}
	return cond
}

/*
source_error returns the first generator error recorded in this case, or
`nil`. The runner checks it for you; call it when a property must stop early
after a malformed generator call.
*/
source_error :: proc(s: ^Source) -> Error {
	return s.err
}
