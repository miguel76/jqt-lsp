####################################################################
# types.jq — v0 type-inference module for jq-lsp
#
# This is a *skeleton*: it covers enough of the AST (identity, field
# access, iteration, pipe, comma, if/then/elif/else, object/array
# construction, a handful of builtins, and the `+` operator's
# overload table) to demonstrate the full pattern end to end —
# Shape IR, cardinality, unification, error/warning diagnostics,
# and a position lookup for completion. Extending it to more of the
# language is mechanical repetition of the same pattern.
#
# AST field names below match gojqparser/query.go exactly (verified
# against that file, not guessed):
#   Query:  op, left, right, term, patterns, func_defs, imports, meta
#   Term:   type, index, func, object, array, number, unary, format,
#           str, if, try, reduce, foreach, label, break, query,
#           suffix_list
#   Term.type (string, after JSON marshaling) keeps its Go constant
#   name IN FULL, e.g. "TermTypeIdentity", "TermTypeIndex",
#   "TermTypeFunc", "TermTypeObject", "TermTypeArray",
#   "TermTypeNumber", "TermTypeString", "TermTypeIf", "TermTypeTry",
#   "TermTypeReduce", "TermTypeForeach", "TermTypeLabel",
#   "TermTypeBreak", "TermTypeQuery", "TermTypeNull", "TermTypeTrue",
#   "TermTypeFalse", "TermTypeRecurse", "TermTypeUnary",
#   "TermTypeFormat" — verified against a live build of gojqparser.
#   (term_type.go's MarshalJSON does NOT strip the "TermType" prefix
#   despite its own "// TODO: gojq. skips prefix" comment — it strips
#   a fixed 5 characters, the literal "gojq." that GoString()
#   prepends, leaving "TermType..." fully intact. This is exactly
#   the kind of thing that's cheap to get wrong reading the source
#   and expensive to debug from an LSP that silently never matches
#   any node — see astdump/ alongside this file for how to regenerate
#   real samples and check assumptions like this one before trusting
#   them.)
#   Index:  name (Token), str (String), start (Query), end (Query),
#           is_slice (bool)
#   Suffix: index, iter (bool), optional (bool)
#   Func:   name (Token), args ([Query])
#   Object: key_vals [{key, key_string, key_query, val}]
#   Array:  query
####################################################################

####################################################################
# Shape IR — a plain JSON value, one of:
#   {"any": true}
#   {"null": true} | {"boolean": true} | {"number": true} | {"string": true}
#   {"array": {"items": Shape}}
#   {"object": {"properties": {name: Shape, ...}, "closed": bool}}
#   {"union": [Shape, ...]}
#   {"var": "T"}                      -- type variable (builtin generics)
#
# Cardinality — one of "one" | "opt" | "many"
#   "one"  exactly one output          (e.g. `.foo`, `1+1`)
#   "opt"  at most one output          (e.g. `.foo?` on a bad input, `select`)
#   "many" zero or more outputs        (e.g. `.[]`, `map`, `empty`)
# Treated as a 3-point lattice one < opt < many; composing two stages
# in sequence takes the max (see card_compose).
#
# A "typed value" flowing through inference is {shape: Shape, cardinality: Cardinality}.
# A builtin/function "signature" is {input: Shape, output: Shape, cardinality: Cardinality}
# — cardinality here means "per one input value".
####################################################################

def t_any: {"any": true};
def t_null: {"null": true};
def t_bool: {"boolean": true};
def t_num: {"number": true};
def t_str: {"string": true};
def t_arr($items): {"array": {"items": $items}};
def t_obj($props; $closed): {"object": {"properties": $props, "closed": $closed}};
def t_union($shapes):
  ( [$shapes[] | if .union then .union[] else . end] # flatten nested unions
  | unique
  ) as $flat
  | if ($flat | length) == 1 then $flat[0]
    elif ($flat | length) == 0 then t_any
    else {"union": $flat}
    end;
def t_var($name): {"var": $name};

def card_rank: {"one": 0, "opt": 1, "many": 2}[.];
def card_compose($a; $b): [$a, $b] | max_by(card_rank);
def card_compose_all($cards): reduce $cards[] as $c ("one"; card_compose(.; $c));

def value(shape; cardinality): {shape: shape, cardinality: cardinality};

####################################################################
# Diagnostic constructor. `$node` must carry a Token-like {start,stop}
# (see `pos_of`, below) — most leaves do, some composite nodes don't,
# which is a known gap: see the note above query_infer.
####################################################################
def diag($node; $severity; $message):
  { start: ($node.start // 0),
    stop: ($node.stop // ($node.start // 0)),
    severity: $severity,      # 1 = Error, 2 = Warning (LSP DiagnosticSeverity)
    message: $message
  };
def err($node; $message): diag($node; 1; $message);
def warn($node; $message): diag($node; 2; $message);

####################################################################
# shape_to_string — tjq-style compact rendering for error messages,
# e.g. "{a: <>, b: [number]}"
####################################################################
def shape_to_string:
  if .any then "<>"
  elif .null then "null"
  elif .boolean then "boolean"
  elif .number then "number"
  elif .string then "string"
  elif .var then "'\(.var)"
  elif .array then "[\(.array.items | shape_to_string)]"
  elif .object then
    ( . as $s
    | ( $s.object.properties
      | to_entries
      | map("\(.key): \(.value | shape_to_string)")
      ) as $fields
    | ( $fields + (if $s.object.closed then [] else ["..."] end)
      | join(", ")
      ) as $inner
    | "{\($inner)}"
    )
  elif .union then "(" + (.union | map(shape_to_string) | join(" | ")) + ")"
  else "?"
  end;

####################################################################
# shape_kind — coarse tag used for compatibility/reachability checks.
# "any" and "var" are wildcards: they're compatible with everything,
# which is the mechanism by which ungrounded input stays silent
# (gradual typing) instead of producing false-positive errors.
####################################################################
def shape_kind: (keys - ["closed"])[0] // "any";

# Do two (non-union) shapes plausibly describe overlapping values?
# v0: same top-level kind, or either side is a wildcard. Doesn't yet
# recurse into object properties / array items — good enough to
# drive the reachability-warning demo below, not a full unifier.
def shape_compatible($a; $b):
  if $a.union then any($a.union[]; shape_compatible(.; $b))
  elif $b.union then any($b.union[]; shape_compatible($a; .))
  else
    ( ($a | shape_kind) as $ka
    | ($b | shape_kind) as $kb
    | $ka == "any" or $kb == "any" or $ka == "var" or $kb == "var" or $ka == $kb
    )
  end;

# Members of a shape, treating a union as its members and anything
# else as a singleton — used to check declared-signature branches
# against an actual (possibly union) input.
def shape_members: if .union then .union else [.] end;

####################################################################
# unify($expected; $actual; $node) — checks that $actual (what we
# inferred is flowing in) is compatible with $expected (what an
# operation requires). Emits an Error diagnostic on definite
# mismatch; stays silent when either side is ungrounded (any/var).
# Returns {diagnostics: [...], ok: bool}.
####################################################################
def unify($expected; $actual; $node; $context):
  if shape_compatible($expected; $actual) then
    {diagnostics: [], ok: true}
  else
    { diagnostics:
        [ err($node;
            "\($context): expected \($expected | shape_to_string), got \($actual | shape_to_string)"
          )
        ],
      ok: false
    }
  end;

####################################################################
# Reachability check: given the actual (possibly union) input shape
# and a signature expressed as a union of accepted branches, warn on
# any declared branch that can't match anything in the actual union.
# This is the mechanism behind "this filter accepts several input
# shapes, but one of them can never occur here."
#
# Only fires when both sides are *concrete* unions/shapes (no any/var
# involved) — with an ungrounded actual input there's nothing to
# warn about, same gradual-typing principle as unify/4.
####################################################################
def check_branch_reachability($actual; $declared_branches; $node; $context):
  ( ($actual | shape_members) as $actual_members
  | if ($actual_members | length) < 2 then
      [] # a single concrete shape naturally uses one branch — nothing to warn about.
         # This check only means something when the actual input is itself a
         # known union (e.g. from an upstream if/then/else, `,`, or `?//`) —
         # otherwise every ordinary, precisely-typed call would "warn" about
         # every overload it isn't using, which is noise, not signal.
    elif any($actual_members[]; shape_kind == "any" or shape_kind == "var") then
      [] # ungrounded input: nothing to say
    else
      [ $declared_branches[] as $branch
      | select(any($actual_members[]; shape_compatible(.; $branch)) | not)
      | warn($node;
          "\($context): \(($branch | shape_to_string)) is never received here " +
          "(actual input is always \($actual | shape_to_string))"
        )
      ]
    end
  );

####################################################################
# Builtin signature table, keyed "name/arity" — same convention
# jq-lsp already uses for its scope environment (see
# lsp.jq:_func_def_env, `"\($f.name)/\($args|length)"`), so this
# composes with the existing env without a translation layer.
#
# First-order entries here are plain {input, output, cardinality}.
# Higher-order builtins (map, select, ...) can't be expressed as a
# static triple — they're handled as special cases in infer_func,
# below, rather than in this table.
####################################################################
def builtin_signatures:
  { "empty/0":  {input: t_any, output: t_any, cardinality: "many"}, # always zero; see note in infer_func
    "not/0":    {input: t_any, output: t_bool, cardinality: "one"},
    "length/0": {input: t_any, output: t_num, cardinality: "one"},
    "keys/0":   {input: t_obj({}; false), output: t_arr(t_str), cardinality: "one"},
    "add/0":    {input: t_arr(t_var("T")), output: t_var("T"), cardinality: "one"}
  };

####################################################################
# Overload table for the `+` operator — the flagship example for
# check_branch_reachability: five declared input-pair "shapes" (here
# simplified to just the left-hand shape; extending to pairs is a
# TODO noted below), any of which is a legitimate warning target if
# the actual left-hand shape is a grounded union missing one of them.
####################################################################
def plus_operator_branches:
  [t_num, t_str, t_arr(t_any), t_obj({}; false), t_null];

def infer_plus($left_t; $right_t; $node):
  ( check_branch_reachability($left_t.shape; plus_operator_branches; $node; "operator +")
  ) as $warnings
  | ( if shape_compatible($left_t.shape; $right_t.shape) | not then
        [err($node;
          "operator +: cannot add \($left_t.shape | shape_to_string) " +
          "and \($right_t.shape | shape_to_string)"
        )]
      else []
      end
    ) as $errors
  | { type: value(t_union([$left_t.shape, $right_t.shape]);
               card_compose($left_t.cardinality; $right_t.cardinality)),
      diagnostics: ($warnings + $errors)
    };

####################################################################
# infer_suffix — one step of a postfix chain: field access,
# iteration, slicing, or `?`. `$chain` items look like
# {index?, iter?, optional?} (see module header for how the leading
# `.index` and `suffix_list` entries are normalized into one list
# before this is called).
####################################################################
def infer_index_by_name($in_t; $name; $node):
  ( $in_t.shape as $s
  | if $s.null then
      { type: value(t_null; "one"), diagnostics: [] }              # .foo on null -> null, no error
    elif $s.object then
      ( $s.object.properties[$name] as $prop
      | if $prop then
          { type: value($prop; "one"), diagnostics: [] }
        elif $s.object.closed then
          { type: value(t_null; "one"), diagnostics: [] }           # known-absent field -> null
        else
          { type: value(t_union([t_any, t_null]); "one"), diagnostics: [] } # open object: unknown
        end
      )
    elif ($s | shape_kind) == "any" or ($s | shape_kind) == "var" then
      { type: value(t_any; "one"), diagnostics: [] }                # ungrounded: stay silent
    else
      # definitely not an object and not null: this is jq's real
      # "Cannot index <type> with string ..." runtime error.
      { type: value(t_any; "one"),
        diagnostics: [err($node; "cannot index \($s | shape_to_string) with \"\($name)\"")]
      }
    end
  );

def infer_iterate($in_t; $node):
  ( $in_t.shape as $s
  | if $s.array then
      { type: value($s.array.items; "many"), diagnostics: [] }
    elif $s.object then
      ( ( $s.object.properties | [.[]]
        | if length == 0 then t_any else t_union(.) end
        ) as $vals
      | { type: value($vals; "many"), diagnostics: [] }
      )
    elif ($s | shape_kind) == "any" or ($s | shape_kind) == "var" then
      { type: value(t_any; "many"), diagnostics: [] }
    else
      { type: value(t_any; "many"),
        diagnostics: [err($node; "cannot iterate over \($s | shape_to_string)")]
      }
    end
  );

def infer_suffix_step($step; $in_t; $node):
  if $step.iter then
    infer_iterate($in_t; $node)
  elif $step.optional then
    # `?`: keep the shape, but if the *previous* step already
    # produced an Error diagnostic, downgrade cardinality to "opt"
    # (suppressed) and drop that error. v0 only looks at diagnostics
    # attached at this exact node; chained `a.b?.c` needs the caller
    # to thread the "suppressed" flag — noted as a TODO.
    { type: value($in_t.shape; card_compose($in_t.cardinality; "opt")), diagnostics: [] }
  elif $step.index.name then
    infer_index_by_name($in_t; $step.index.name.str; $node)
  elif $step.index.is_slice then
    # slicing: shape unchanged, cardinality unchanged (never fans out)
    unify(t_union([t_arr(t_any), t_str]); $in_t.shape; $node; "slice") as $u
    | { type: value($in_t.shape; $in_t.cardinality), diagnostics: $u.diagnostics }
  elif $step.index then
    # computed non-slice index, e.g. .[0] or .[$k]: v0 doesn't track
    # array element positions or evaluate the key expression's own
    # type, so this degrades to `any` rather than a real element type.
    { type: value(t_any; $in_t.cardinality), diagnostics: [] }
  else
    { type: $in_t, diagnostics: [] }
  end;

def full_suffix_chain:
  ( (if .term.type == "TermTypeIndex" then [{index: .term.index}] else [] end)
  + (.term.suffix_list // [])
  );

####################################################################
# infer($node; $env; $in_t) — the main entrypoint, and the only
# self-recursive def in the cycle (jq forbids a def from calling a
# sibling def that appears *later* in the file — only calling itself
# is allowed — so the former infer_term/infer_func split had to be
# folded back into one function; the helpers above it, which never
# call back into infer, stay separate).
#
# $node is a Query (or Term wrapped as {term: ...}), $env is
# jq-lsp's existing scope array (from query_walk), $in_t is the
# {shape, cardinality} flowing in. Returns
# {type: {shape, cardinality}, diagnostics: [...]}.
####################################################################
def infer($node; $env; $in_t):
  if $node.op then
    if $node.op == "|" then
      ($node.left | infer(.; $env; $in_t)) as $l
      | ($node.right | infer(.; $env; $l.type)) as $r
      | { type: $r.type, diagnostics: ($l.diagnostics + $r.diagnostics) }
    elif $node.op == "," then
      ($node.left | infer(.; $env; $in_t)) as $l
      | ($node.right | infer(.; $env; $in_t)) as $r
      | { type: value(t_union([$l.type.shape, $r.type.shape]);
                 card_compose($l.type.cardinality; $r.type.cardinality)),
          diagnostics: ($l.diagnostics + $r.diagnostics)
        }
    elif $node.op == "+" then
      ($node.left | infer(.; $env; $in_t)) as $l
      | ($node.right | infer(.; $env; $in_t)) as $r
      | infer_plus($l.type; $r.type; $node) as $p
      | { type: $p.type, diagnostics: ($l.diagnostics + $r.diagnostics + $p.diagnostics) }
    else
      # other ops (-,*,/,%,comparisons,and,or,//,?//,=,|=,...): not
      # yet modeled, stay silent. Same shape of work as `+` above.
      { type: value(t_any; "one"), diagnostics: [] }
    end
  elif $node.term then
    ( $node.term as $t
    | if $t.type == "TermTypeIdentity" and (($t.suffix_list // []) | length) == 0 then
        { type: $in_t, diagnostics: [] }
      elif $t.type == "TermTypeIdentity" or $t.type == "TermTypeIndex" then
        # walk the suffix chain (leading .index, if any, plus suffix_list)
        reduce ($node | full_suffix_chain)[] as $step
          ({type: $in_t, diagnostics: []};
           infer_suffix_step($step; .type; $node) as $r
           | {type: $r.type, diagnostics: (.diagnostics + $r.diagnostics)}
          )
      elif $t.type == "TermTypeNumber" then
        { type: value(t_num; "one"), diagnostics: [] }
      elif $t.type == "TermTypeString" and (($t.str.queries // []) | length) == 0 then
        { type: value(t_str; "one"), diagnostics: [] }
      elif $t.type == "TermTypeString" then
        # interpolated string: contents don't affect the result shape
        # (always a string), but sub-queries still need to be inferred
        # for their own diagnostics.
        ( [ $t.str.queries[] | infer(.; $env; $in_t) ] ) as $sub
        | { type: value(t_str; "one"), diagnostics: [$sub[].diagnostics] | add }
      elif $t.type == "TermTypeTrue" or $t.type == "TermTypeFalse" then
        { type: value(t_bool; "one"), diagnostics: [] }
      elif $t.type == "TermTypeNull" then
        { type: value(t_null; "one"), diagnostics: [] }
      elif $t.type == "TermTypeFunc" then
        # dispatch for term.func nodes (name(args...) calls).
        # Unresolved/user-defined functions fall back to `any`,
        # silently — this is where per-module signature caching (the
        # .jqt.json sidecar idea) plugs in later: look up $env's
        # resolved def, then that def's cached signature, before
        # giving up to `any`.
        ( $t.func.name.str as $name
        | ($t.func.args // []) as $args
        | ($args | length) as $arity
        | "\($name)/\($arity)" as $key
        | if $name == "map" and $arity == 1 then
            # map(f): input array<X> -> output array<Y>, Y = f applied to X
            ( unify(t_arr(t_var("T")); $in_t.shape; $node; "map") as $u
            | ( if $in_t.shape.array then $in_t.shape.array.items else t_any end
              ) as $elem_t
            | ($args[0] | infer(.; $env; value($elem_t; "one"))) as $mapped
            | { type: value(t_arr($mapped.type.shape); "one"),
                diagnostics: ($u.diagnostics + $mapped.diagnostics)
              }
            )
          elif $name == "select" and $arity == 1 then
            # select(f): input X -> output X, 0 or 1 times
            ( ($args[0] | infer(.; $env; $in_t)) as $cond
            | { type: value($in_t.shape; "opt"), diagnostics: $cond.diagnostics }
            )
          elif builtin_signatures[$key] then
            ( builtin_signatures[$key] as $sig
            | unify($sig.input; $in_t.shape; $node; $name) as $u
            # substitute a single type var (if any) with the concrete
            # input — v0 simplification, see module header; doesn't
            # handle multiple distinct vars in one signature.
            | ( $sig.output | walk(if type == "object" and has("var") then $in_t.shape else . end)
              ) as $out_shape
            | { type: value($out_shape; card_compose($in_t.cardinality; $sig.cardinality)),
                diagnostics: $u.diagnostics
              }
            )
          else
            # not in the table: either a user def (look up $env + a
            # future per-module signature cache) or a builtin we
            # haven't modeled yet. Stay silent — gradual typing.
            { type: value(t_any; "many"), diagnostics: [] }
          end
        )
      elif $t.type == "TermTypeArray" then
      ( if $t.array.query then
          ($t.array.query | infer(.; $env; $in_t)) as $inner
          | { type: value(t_arr($inner.type.shape); "one"), diagnostics: $inner.diagnostics }
        else
          { type: value(t_arr(t_any); "one"), diagnostics: [] } # empty array literal `[]`
        end
      )
    elif $t.type == "TermTypeObject" then
      ( ( reduce ($t.object.key_vals // [])[] as $kv
            ({props: {}, diagnostics: []};
             ( ($kv.key.str // $kv.key_string.str) ) as $name
             | if $name and $kv.val then
                 ($kv.val | infer(.; $env; $in_t)) as $v
                 | { props: (.props + {($name): $v.type.shape}),
                     diagnostics: (.diagnostics + $v.diagnostics)
                   }
               else
                 # computed key ({(expr): val}): v0 can't name the
                 # property statically, so the object degrades to open.
                 .
               end
            )
        ) as $built
      | { type: value(t_obj($built.props; ($t.object.key_vals | all(.key or .key_string))); "one"),
          diagnostics: $built.diagnostics
        }
      )
    elif $t.type == "TermTypeIf" then
      ( ($t.if.then | infer(.; $env; $in_t)) as $then_t
      | ( [$t.if.elif[]? | .then | infer(.; $env; $in_t)] ) as $elif_ts
      | ( if $t.if.else then [$t.if.else | infer(.; $env; $in_t)] else [] end ) as $else_ts
      | ([$then_t] + $elif_ts + $else_ts) as $branches
      | { type: value(t_union([$branches[].type.shape]);
                 card_compose_all([$branches[].type.cardinality])),
          diagnostics: [$branches[].diagnostics] | add
        }
      )
      elif $t.type == "TermTypeQuery" then
        $t.query | infer(.; $env; $in_t)
      else
        # try/reduce/foreach/label/break/recurse/format/unary: not yet
        # modeled — same pattern as the ops above, stay silent.
        { type: value(t_any; "one"), diagnostics: [] }
      end
    )
  else
    { type: $in_t, diagnostics: [] }
  end;

####################################################################
# Entrypoints for lsp.jq to call.
####################################################################

# Whole-file diagnostics, ready to concatenate into the existing
# `diagnostics: [...]` array in the didOpen/didChange handler.
# $input_shape: the grounded top-level input type if known (from a
# JSON Schema the user supplied), else t_any.
def infer_diagnostics($uri; $env; $input_shape):
  ( . as $query
  | infer($query; $env; value($input_shape; "one")) as $r
  | $r.diagnostics
  );

# Type flowing out of a (sub-)query — the completion entrypoint.
#
# This is deliberately NOT "find the node at cursor position X in the
# full parsed document" — that needs every AST node to carry its own
# span, and they don't (Query nodes have none; even jq-lsp's own
# query_token/qe_from_params, used for its existing completion, only
# resolves position for func/format/break/variable tokens, not
# arbitrary points inside a suffix chain — same gap, not a new one).
#
# Instead, follow the same trick real editors use for "what type
# would go here": re-parse the TEXT UP TO THE CURSOR as its own
# (possibly ragged) query, and infer *that*. Its output type is
# exactly "what's flowing into the cursor". Concretely, from
# lsp.jq's textDocument/completion handler:
#
#   $params.position as $pos
#   | ($file.text[0 : ($pos | lc_to_pos($file.line_lens))]) as $prefix_src
#   # trim back to the last complete token boundary if $prefix_src
#   # doesn't parse on its own (e.g. ends mid "." with nothing after) —
#   # a few characters of lookback, not full error-recovery parsing.
#   | ($prefix_src | query_fromstring) as $prefix_file
#   | ($prefix_file.query | infer_output_type(builtin_env; $input_shape))
#   | if .shape.object then .shape.object.properties | keys[] else empty end
#   # ... build CompletionItems from these, same as the existing
#   # function/variable completions in that handler.
#
# This sidesteps needing per-node position lookup in v0 entirely, at
# the cost of only working right after a real (if partial) parse —
# good enough for the common "type `.` and see field names" case,
# not yet for every mid-token cursor position.
def infer_output_type($env; $input_shape):
  ( infer(.; $env; value($input_shape; "one")) | .type );
