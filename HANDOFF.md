# jqt-lsp — project handoff

Fork: `miguel76/jqt-lsp`, forked from `wader/jq-lsp`. This doc is the
state of the design/implementation as of the chat session that
preceded this Claude Code session — read it first, then verify
against the actual repo tree (the description below of "what's
where" reflects what was handed off, not a live read of the repo).

## The goal, in one paragraph

A static type checker for jq — TypeScript-for-jq — with **optional**
type annotations (types can be named, and can be derived from
external JSON Schemas), delivered as a standalone tool that also
works as a real IDE experience (VS Code first, LSP so other editors
work too): red squigglies for type errors, warnings for jq filters
whose declared input-shape branches can provably never be hit given
what's known about the data flowing in, and completion that suggests
real field names once the checker knows the shape at the cursor.
Module/`import`-aware type propagation across files is an explicit
non-goal for v0, but the design (see "Type IR" below) tries not to
foreclose it.

## Why this architecture (decision record)

- **Fork `wader/jq-lsp` rather than build an LSP server from
  scratch.** It already has a modified `gojq`-based parser with
  error-recovery for mid-typing input, module/`include`/`import`
  resolution, hover, goto-def, and basic completion — all the
  IDE-plumbing that's orthogonal to the type system and expensive to
  get right. Verified this is real, working code by cloning it, not
  just reading its README.
- **The type-inference *rules* are written in jq itself**, not Go —
  and this isn't a stretch: jq-lsp's *entire* existing LSP protocol
  logic already lives in `lsp/lsp.jq` (24K of jq), with `lsp/lsp.go`
  as a thin ~300-line Go shim supplying only what jq can't do itself
  (file I/O, the JSON-RPC transport, and `query_fromstring`/
  `query_tostring` — native wrappers around `gojqparser.Parse`). So
  "write the type checker mostly in jq" is this project's existing
  shape, not a bolt-on.
- **No subprocess boundary.** Because `gojq` (the parser jq-lsp
  wraps) is a Go *library*, the whole server — parse, run the
  jq-authored inference rules, publish diagnostics — runs in one Go
  process. No Python/TS glue layer ended up being needed anywhere.
- **Go edits are deliberately minimal.** The only required Go change
  to add the whole type layer was one `//go:embed types.jq` line in
  `lsp/lsp.go` (see `wiring.patch`) — jq-lsp's module loader already
  opens any embedded `<name>.jq` file on `include "<name>";`, so
  everything else is jq.

## Type IR (the actual design)

A Shape is a plain JSON value:
```
{"any": true} | {"null": true} | {"boolean": true} | {"number": true} | {"string": true}
{"array": {"items": Shape}}
{"object": {"properties": {name: Shape, ...}, "closed": bool}}
{"union": [Shape, ...]}
{"var": "T"}                         -- type variable, builtin generics only in v0
```
Cardinality is `"one" | "opt" | "many"` (exactly-one / at-most-one /
zero-or-more) — a 3-point lattice, composed by `max` across a
sequence (`card_compose`). A "typed value" is `{shape, cardinality}`;
a function signature is `{input, output, cardinality}`.

This is deliberately **not** JSON Schema, despite JSON Schema being
the obvious first instinct for the *named-types* requirement
(`$defs`/`$ref` gives that for free). The open design question,
**not yet decided**, is whether to:
(a) keep this bespoke IR and add a JSON-Schema *import/export* layer
    for interop with externally-supplied schemas, or
(b) rebuild the shape layer on JSON Schema (or JSON Type Definition,
    RFC 8927, which has discriminated unions as a first-class
    construct — closer to how `?//` and `if/then/else` naturally
    produce union types) with a custom vocabulary extension for
    cardinality/function-signature/type-variable, which plain JSON
    Schema can't express.
This was flagged but deliberately left open in the original design
discussion — worth resolving before the IR gets load-bearing in more
places.

## What's implemented, and — important — what's actually *tested*

Everything in `lsp/types.jq` was validated against **real
`gojqparser` output**, not hand-written AST fixtures: a small Go
program (`astdump/main.go`, included in the fork) was built and run
against a live checkout to dump actual ASTs for representative
snippets, and `infer()` was run against them.

Confirmed working, end to end, against real parses:
- Field access, including chained (`.foo.bar` through two nested
  objects), with jq's real null-propagation semantics (`.foo` on
  `null` → `null`, not an error; on a definitely-incompatible shape
  like a number → a real Error diagnostic).
- `.[]` iteration (array and object), `.[0]`, `.[1:3]` slicing
  (shape unchanged, cardinality unchanged — slicing doesn't fan out).
- `|` (pipe composition), `,` (comma → union of branch types).
- `if/then/elif/else` (branch-unioning, with automatic dedup when
  branches agree — `t_union` collapses to a single shape when all
  members are equal).
- `map(f)` and `select(f)` as hand-written intrinsics (higher-order,
  can't be static table entries).
- Object and array literal construction.
- The `+` operator's 5-way overload table, **and** the flagship
  "unreachable branch" warning: correctly silent on ordinary
  singleton-typed uses, correctly warns only when the actual input
  is a genuine multi-member union (e.g. from an upstream
  `if/then/else`) and one declared branch can't match any member.
- The completion entrypoint (`infer_output_type`): tested against a
  *real reparse* of the literal text `.items[] | .` with input shape
  `{items: [{name, price}]}`, correctly resolving `name`/`price` as
  the field completions to offer.

**Not yet modeled** (falls through to a silent `any`, by design —
see "gradual typing" note below): `-`, `*`, `/`, `%`, comparisons,
`and`/`or`, `//`, `?//`, `try`/`catch`, `reduce`, `foreach`,
`label`/`break`, destructuring patterns, `@format` strings. Each is
the same shape of work as `+` (table-driven) or the suffix-chain
handling (structural) — mechanical extension, not new design.

**Explicitly stubbed / next concrete steps, in rough priority order:**
1. **Wire completion into the actual handler.** `infer_output_type`
   works (tested, see above) but `wiring.patch` doesn't yet call it
   from `textDocument/completion` in `lsp.jq`. The approach is
   documented in the doc-comment directly above `infer_output_type`
   in `types.jq`: slice the document text to the cursor, reparse that
   prefix with the existing native `query_fromstring`, run `infer`
   on it, offer `.shape.object.properties` keys via the (already
   added) `CompletionItemKindField` constant. Deliberately sidesteps
   needing per-node position lookup in the full document (see next
   point).
2. **General "type at cursor position" for anywhere, not just after a
   full reparse.** Real limitation, not just laziness: `Query`/`Term`
   AST nodes mostly don't carry their own span (only specific leaf
   tokens do — e.g. `Index.name`, `Func.name`). jq-lsp's *own*
   existing `query_token`/`qe_from_params` (used for its current
   completion/hover/goto-def) has the identical limitation — it only
   resolves position for func/format/break/variable tokens, not
   arbitrary points inside a suffix chain. This is a pre-existing gap
   in upstream jq-lsp, not something introduced here, and fixing it
   properly benefits hover/goto-def too, not just typed completion.
3. **Per-module signature caching**, for the deferred but
   design-relevant module/`import` requirement. `infer`'s
   `TermTypeFunc` case already has the fallback point: anything not
   in `builtin_signatures` and not a special-cased intrinsic
   (`map`/`select`) currently returns `any` silently. The plan (not
   implemented): look up the resolved `def` via `$env` (jq-lsp's
   `query_walk` already computes this scope-resolution environment),
   then check a per-module signature cache — a `.jqt.json`-style
   sidecar generated by running `infer` over that module once,
   analogous to a TypeScript `.d.ts` — before giving up to `any`.
   jq-lsp's existing include/import *resolution* can be reused as-is;
   only the signature-caching layer on top is new work.
4. **Extend language coverage** per the "not yet modeled" list above.
5. **Real unification** for signatures with more than one distinct
   type variable (current `walk`-based substitution only handles a
   single `{"var": "T"}` per signature correctly).
6. **Decide the JSON-Schema-vs-bespoke-IR question** above before
   it's expensive to change.
7. **Build/test the actual Go binary end-to-end.** This was *not*
   done in the handoff session — only `types.jq`'s logic was tested
   (via `jq -L`, calling `infer` directly against real ASTs) and the
   patched `lsp.jq` was confirmed to *compile* as one program the
   same way jq-lsp's `embed.FS` loader would load it. `go build &&
   go test ./...` in the actual fork was never run. **Do this
   first**, before anything else, to catch anything Go-version- or
   integration-specific that couldn't be seen from jq-level testing
   alone.

## Design principle worth preserving: silence over false positives

Every check in `types.jq` is written to stay silent (return `any`,
no diagnostic) rather than guess when a shape is ungrounded (`any`/
`var`) or a construct isn't modeled yet. This is deliberate gradual
typing, not laziness, and it's the thing that makes an incrementally-
built checker usable rather than naggy — resist the temptation to
make an unmodeled construct "helpfully" flag something; false
positives are far more costly to user trust here than false
negatives (an unmodeled op just silently not catching a bug is
fine — that's the current state of jq-lsp anyway; an unmodeled op
inventing a spurious error is a regression).

## Hard-won gotchas (each cost real debugging time — don't relitigate)

1. **`Term.type` keeps its full Go constant name in JSON**:
   `"TermTypeIdentity"`, `"TermTypeIndex"`, `"TermTypeFunc"`, etc. —
   *not* `"Identity"`/`"Index"` as a literal reading of
   `term_type.go`'s `// TODO: gojq. skips prefix` comment suggests.
   `MarshalJSON` strips a fixed 5 characters (the literal `"gojq."`
   `GoString()` prepends), not the `TermType` prefix. Caught only by
   building `gojqparser` and diffing real output — this is exactly
   why `astdump/` exists; use it before trusting a reading of the Go
   source for any new AST shape you haven't dumped yet.
2. **jq forbids forward references between sibling top-level
   `def`s** — a function can call itself (direct recursion is fine)
   but not a sibling `def` that appears later in the file. This is
   why `infer`/`infer_term`/`infer_func` ended up merged into one
   self-recursive function instead of three mutually-recursive ones.
   Keep this in mind before splitting `infer` back apart for
   readability — either keep the split one-directional (only earlier
   defs calling later ones — wait, it's the reverse: only *later*
   defs may call *earlier* ones) or keep it merged.
3. **`reduce EXPR as $x (init; update)` is a complete expression** —
   you can't tack `as $var` onto the end of the `(init; update)`
   block; wrap the whole `reduce ... (...)` in parens first if you
   need to bind its result.
4. **`shape_compatible` must recurse into unions explicitly** —
   comparing a union's own top-level "kind" tag against another
   shape doesn't do the right thing; it needs to check "does *any*
   member of side A work with side B" (and vice versa).
5. **The reachability-warning check must require the *actual* side to
   already be a multi-member union** before comparing against
   declared branches — checking a singleton concrete shape against a
   multi-branch signature "warns" about every branch it isn't using,
   which is just noise on every ordinary, precisely-typed call.
6. `apt-get install golang-go` gets Go **1.22** in this kind of
   sandbox; the repo's `go.mod` wants **1.24** (for
   `unicode/utf16.RuneLen`, added in 1.24) and the toolchain
   auto-download needs `proxy.golang.org`, which is typically
   network-blocked. A local one-line shim for that function was used
   *only* to validate `types.jq` against real ASTs in that sandbox —
   it was never meant to ship, and should not be in the fork; if it
   somehow is, revert it and get a real Go 1.24 toolchain instead.

## Testing workflow to keep using

No need for the full LSP harness to iterate on `types.jq` itself:

```sh
# from repo root, once astdump/ exists there
go run ./astdump ".foo" "map(.x)" '"custom query"' > samples.json

# then, from lsp/ (or wherever types.jq lives)
jq -n -L . --slurpfile ast_samples ../samples.json '
  include "types";
  $ast_samples[0]["<query>"] | infer(.; []; value(<some Shape>; "one"))
'
```
This is exactly how every piece of `types.jq` was validated — fast,
no Go rebuild needed after the first `astdump` run, and it exercises
the real parser instead of hand-typed AST fixtures that can (and, in
this project already did, once) silently diverge from reality.
