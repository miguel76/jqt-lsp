// astdump is a small standalone tool for checking assumptions about
// gojqparser's JSON AST shape against reality instead of against
// source-code comments (which can be misleading — see types.jq's
// header comment for a real example this caught: Term.type keeps
// its full "TermType..." prefix in JSON, despite a "// TODO: gojq.
// skips prefix" comment in term_type.go suggesting otherwise).
//
// Usage, from the root of a jq-lsp checkout:
//   go run ./astdump ".foo" ".[] | select(.x > 1)" "map(.y)"
//
// Prints, for each query argument, its query_fromstring-equivalent
// JSON AST (i.e. exactly what lsp.go's native `query_fromstring`
// function hands to jq). With no arguments, dumps a fixed set of
// representative samples covering the constructs types.jq models.
package main

import (
	"encoding/json"
	"fmt"
	"os"

	"github.com/wader/jq-lsp/gojqparser"
)

var defaultSamples = []string{
	".",
	".foo",
	".foo?",
	".foo.bar",
	".[]",
	".[0]",
	".[1:3]",
	"1 + 2",
	"map(.x)",
	"select(.x > 1)",
	"if .a then 1 elif .b then 2 else 3 end",
	"{a: .x, b: 2}",
	"[.a, .b]",
	"\"hello \\(.name)\"",
}

func main() {
	queries := os.Args[1:]
	if len(queries) == 0 {
		queries = defaultSamples
	}

	out := make(map[string]any, len(queries))
	for _, q := range queries {
		query, err := gojqparser.Parse(q)
		if err != nil {
			out[q] = map[string]any{"parse_error": err.Error()}
			continue
		}
		b, err := json.Marshal(query)
		if err != nil {
			out[q] = map[string]any{"marshal_error": err.Error()}
			continue
		}
		var v any
		if err := json.Unmarshal(b, &v); err != nil {
			out[q] = map[string]any{"unmarshal_error": err.Error()}
			continue
		}
		out[q] = v
	}

	enc := json.NewEncoder(os.Stdout)
	enc.SetIndent("", "  ")
	if err := enc.Encode(out); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
