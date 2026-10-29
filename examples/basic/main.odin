// Example basic finds and shrinks a bug in a run-length encoder. Run it with `odin run examples/basic`.
package main

import qc "../.."
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"

// encode writes each run as a count followed by the byte, so "aaab" becomes "3a1b".
// The bug: it assumes every count is a single digit.
encode :: proc(text: string, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	for i := 0; i < len(text); {
		j := i
		for j < len(text) && text[j] == text[i] {
			j += 1
		}
		strings.write_int(&b, j - i)
		strings.write_byte(&b, text[i])
		i = j
	}
	return strings.to_string(b)
}

// decode reverses encode, reading one digit of count per run.
decode :: proc(code: string, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	for i := 0; i + 1 < len(code); i += 2 {
		n, _ := strconv.parse_int(code[i:i + 1])
		for _ in 0 ..< n {
			strings.write_byte(&b, code[i + 1])
		}
	}
	return strings.to_string(b)
}

// round_trip is the property: decoding an encoding gives back the input.
round_trip :: proc(s: ^qc.Source) -> bool {
	text := qc.string_of(s, "ab", 0, 40)
	code := encode(text)
	qc.note(s, "encoded as", code)
	return decode(code) == text
}

main :: proc() {
	result, err := qc.run(round_trip, {cases = 500, seed = 2026})
	defer qc.result_destroy(&result)
	if err != nil {
		fmt.eprintln("quickcheck error:", err)
		os.exit(1)
	}
	switch result.status {
	case .Passed:
		fmt.println("round_trip held for", result.cases, "cases")
	case .Gave_Up:
		fmt.println("gave up after", result.discarded, "discarded cases")
	case .Failed:
		fmt.printfln("round_trip failed after %d cases; %d shrinks gave this minimal input:", result.cases, result.shrinks)
		fmt.print(result.counterexample)
		fmt.println("replay it with seed", result.seed)
	}
}
