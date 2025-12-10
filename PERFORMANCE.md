# Freyja Performance Notes

This document captures performance characteristics and benchmarking results for Freyja.

## Continuation Queue Performance

### Background

Freyja's `Freer` monad uses a continuation queue to track "what to do next" after each effect is interpreted. The `bind` operation appends continuations to this queue using `Enum.concat/2`, which is O(n) where n is the queue length.

There was concern that deeply nested computations could exhibit O(n²) behavior due to repeated queue concatenation.

### Benchmark Design

We tested four patterns to isolate the queue overhead:

1. **State/Nested** - Real `State.get/put` effects at each step, nested binds (typical `con`/`hefty` usage)
2. **State/Chained** - Real effects at each step, chained binds
3. **Min/Nested** - Single effect, then pure nested computation (isolates bind overhead)
4. **Min/Chained** - Single effect, then chained identity binds (isolates queue construction overhead)

**Nested binds** (what macros generate):
```elixir
State.get()
|> Freer.bind(fn n ->
  State.put(n + 1)
  |> Freer.bind(fn _ ->
    nested_loop(target)  # recursive call
  end)
end)
```

**Chained binds** (pathological case):
```elixir
base = State.get()
Enum.reduce(1..n, base, fn _i, acc ->
  acc |> Freer.bind(fn x -> Freer.pure(x) end)
end)
```

### Results

All times include both construction and execution (median of 5 runs):

| Target | State/Nested | State/Chained | Min/Nested | Min/Chained |
|--------|--------------|---------------|------------|-------------|
| 500    | 170 µs       | 142 µs        | 4 µs       | 8 µs        |
| 1,000  | 258 µs       | 255 µs        | 8 µs       | 19 µs       |
| 2,000  | 526 µs       | 511 µs        | 16 µs      | 31 µs       |
| 5,000  | 1.24 ms      | 1.28 ms       | 38 µs      | 84 µs       |
| 10,000 | 2.5 ms       | 2.56 ms       | 81 µs      | 219 µs      |

### Analysis

**State columns (real effects):** Nested and chained perform identically (~0.25ms per 1000 operations). Real effect interpretation dominates any queue overhead.

**Min columns (pure computation):**
- **Min/Nested** scales linearly: 8µs → 81µs (10x time for 20x operations)
- **Min/Chained** scales worse than linear: 8µs → 219µs (27x time for 20x operations)

The O(n²) queue construction overhead is visible in Min/Chained, but even at 10,000 chained binds it's only 219µs - negligible compared to any real work.

**Key insight**: The O(n²) occurs during **chain construction**, not execution. Each `Freer.bind` on an `Impure` value appends to the queue using `Enum.concat/2`, which is O(queue_length). However, `bind` on a `Pure` value immediately evaluates (monad left identity law), so typical nested patterns don't accumulate long queues.

### Why It Doesn't Matter in Practice

1. **Macro expansion produces nested binds, not chained binds**

   The `con` and `hefty` macros expand to nested `bind` calls:
   ```elixir
   con do
     x <- a()
     y <- b()
     z <- c()
     return(x + y + z)
   end
   ```
   Becomes:
   ```elixir
   a() |> bind(fn x ->
     b() |> bind(fn y ->
       c() |> bind(fn z ->
         pure(x + y + z)
       end)
     end)
   end)
   ```

   Each `bind` adds only ONE continuation to the queue. After interpretation, we pop and apply - the queue never accumulates.

2. **Real effect work dominates**

   In realistic computations, interpreting effects (database queries, state management, I/O) takes orders of magnitude longer than queue manipulation.

3. **Chained binds lose intermediate access**

   The chained pattern `a() |> bind(f) |> bind(g) |> bind(h)` can only pass one value forward through the chain. You lose access to intermediate results, making this pattern rarely useful for real code.

### Recommendations

- **Don't worry about queue performance** for typical `con`/`hefty` usage
- **Avoid explicit chained binds** - use nested binds (via macros) for cleaner code and access to all intermediate values
- **If you need 10,000+ sequential steps**, consider restructuring as batched operations

### Potential Future Optimization

If pathological cases become a concern, the queue could be replaced with a type-aligned functional queue (banker's queue or difference list) providing O(1) amortized concatenation. However, the benchmarks suggest this optimization is not currently necessary.

See [bootstarted/effects queue implementation](https://github.com/bootstarted/effects/blob/master/lib/queue.ex) for a reference implementation.

---

## Comparison with Other Effect Systems

### Overhead Ratios

Comparing effectful vs non-effectful performance across different systems:

| System | Language | Overhead vs Pure | Notes |
|--------|----------|------------------|-------|
| **Freyja** | Elixir | ~17-21x | Initial encoding with higher-order effects |
| **freer-simple** | Haskell | ~75x | Initial encoding, similar architecture to Freyja |
| **too-fast-too-free** | Haskell | ~2x | Final encoding |
| **polysemy** | Haskell | Variable | Removed "zero-cost" claims; GHC optimizations unreliable |
| **mtl** | Haskell | ~1x (baseline) | Monad transformers, not extensible |

Sources:
- Freyja: `bench/queue_benchmark.exs` (State/Nested vs Pure/Recurse)
- Haskell systems: Sandy Maguire's ["Freer Monads: Too Fast, Too Free"](https://reasonablypolymorphic.com/blog/too-fast-too-free/)

### Context

From the polysemy README:
> "Previous versions of this README mentioned the library being *zero-cost*... it turned out that optimizations we depend on... **don't work in bigger, multi-module programs**... this **isn't a polysemy-specific problem** - basically **all popular effects libraries** ended up being bitten by variation of this problem"

From Sandy Maguire:
> "Yes, freer monads are today somewhere around 30x slower than the equivalent mtl code. That's roughly on par with Python, but be honest, you've deployed Python services in the past and they were fast enough. And besides, the network speed already dominates your performance—you're IO-bound anyway."

**Freyja's ~17-21x overhead is competitive** with other initial-encoding effect systems and is likely acceptable for most real-world applications where I/O dominates.

---

## Trade-offs for Performance Improvement

### Initial vs Final Encoding

Freyja uses an **initial encoding** where computations are represented as data structures:

```elixir
# Initial: computation as data
%Impure{sig: State, data: %Get{}, q: [&Freer.pure/1]}
```

The alternative **final encoding** represents computations as functions awaiting an interpreter:

```haskell
-- Final: computation as function
newtype Freer f a = Freer
  { runFreer :: forall m. Monad m => (forall t. f t -> m t) -> m a }
```

### Why Final Encoding is Faster

With initial encoding, every `bind` allocates a node in a data structure. With final encoding, `bind` just composes functions - no allocation, and everything fuses at runtime.

This is how `too-fast-too-free` achieves ~2x overhead vs freer-simple's ~75x.

### What Final Encoding Cannot Do

Final encoding makes computations **opaque functions** rather than **inspectable data**. This breaks several Freyja features:

| Feature | Initial Encoding | Final Encoding |
|---------|------------------|----------------|
| Higher-order effects (Bracket, Catch, Local) | ✅ Full support | ❌ Very difficult |
| Effect logging | ✅ Can inspect/record effects | ❌ Computation is opaque |
| Serializable continuations | ✅ Data can be serialized | ❌ Can't serialize functions |
| Replay/resume from logs | ✅ Core feature | ❌ Not possible |
| Coroutine suspension | ✅ Capture continuation as data | ❌ No data to capture |

### Higher-Order Effects Problem

Higher-order effects take **effectful computations as arguments**:

```elixir
# Higher-order: sub-computations as arguments
%Bracket{acquire: computation, use: fn resource -> comp end, release: fn resource -> comp end}
%Catch{computation: comp, handler: fn error -> recovery_comp end}
```

With initial encoding, these sub-computations are data that can be:
- Inspected and transformed
- Run multiple times
- Run in different contexts
- Intercepted for logging

With final encoding, sub-computations are opaque functions. You can only call them - you can't control how they interact with effect handlers.

### Hefty Algebras and Final Encoding

Freyja uses **hefty algebras** (from "Hefty Algebras: Modular Elaboration of Higher-Order Algebraic Effects") to handle higher-order effects through elaboration into first-order effects.

There is no established "final encoding of hefty algebras" in the research literature. The Haskell ecosystem is still actively researching this problem:

- **fused-effects**: Uses weaving for higher-order effects, complex boilerplate
- **effectful**: Sidesteps by using `IO` + `ReaderT` as base (not purely functional)
- **polysemy**: Hybrid approach, still has performance issues in practice

### Recommendation

Given Freyja's design goals:

1. **Effect logging and replay** - requires inspectable computation data
2. **Resumable computations** - requires serializable continuations
3. **Higher-order effects** - requires hefty algebra support

The initial encoding is the correct choice. The ~17-21x overhead is the cost of these capabilities, and it's competitive with other systems providing similar features.

If pure interpretation performance becomes critical for a specific use case, consider:
- Optimizing the hot path (we already replaced `Enum.concat` with `++` for ~6% improvement)
- Reducing protocol dispatch overhead (inline signatures)
- Using direct function calls for simple effects that don't need logging

---

## Comparison with a Hypothetical Dynamic Evidence-Passing Approach

### Background

Koka and other modern effect systems use **evidence-passing** for effect dispatch. In this approach:

1. An "evidence vector" maps effect types to their handlers (like a vtable in OO systems)
2. Effect operations look up the handler via O(1) indexed access
3. The handler is called directly with a continuation parameter
4. No intermediate data structures (like `Impure` nodes) are allocated

This is fundamentally different from Freer's approach where every effect operation:
1. Allocates a `Sig` struct for the effect signature
2. Allocates an `Impure` node wrapping the signature
3. Returns up the call stack
4. The handler pattern matches on the signature type
5. If resuming, builds a new `Impure` with an updated continuation queue

The question: **how much of Freer's overhead comes from node allocation and handler matching vs continuation capture?**

### Benchmark Design

We extended the queue benchmark with several additional approaches:

1. **Monad/Nested** - Simple state monad `fn state -> {val, state}` with nested binds (no effect system)
2. **Ev/Nested** - Evidence-passing with nested map lookup `%{effect => %{op => handler}}`
3. **Evf/Nested** - Flat evidence-passing with single map lookup `%{state_get => handler}`

These isolate different costs:
- **Monad/Nested** shows the baseline cost of a state monad abstraction
- **Ev/Nested** adds dynamic handler dispatch via nested maps
- **Evf/Nested** adds dynamic handler dispatch via flat maps (single lookup)

### Results

All times include both construction and execution (median of 5 runs):

| Target | State/Nest | State/Chain | Min/Nest | Min/Chain | Pure/Reduce | Pure/Recur | Monad/Nest | Ev/Nest | Evf/Nest |
|--------|------------|-------------|----------|-----------|-------------|------------|------------|---------|----------|
| 500    | 123 µs     | 136 µs      | 4 µs     | 5 µs      | 5 µs        | 4 µs       | 7 µs       | 24 µs   | 15 µs    |
| 1,000  | 255 µs     | 249 µs      | 8 µs     | 15 µs     | 17 µs       | 16 µs      | 16 µs      | 59 µs   | 33 µs    |
| 2,000  | 503 µs     | 498 µs      | 16 µs    | 37 µs     | 18 µs       | 32 µs      | 30 µs      | 97 µs   | 57 µs    |
| 5,000  | 1.24 ms    | 1.24 ms     | 44 µs    | 102 µs    | 45 µs       | 81 µs      | 73 µs      | 243 µs  | 161 µs   |
| 10,000 | 2.44 ms    | 2.54 ms     | 76 µs    | 186 µs    | 160 µs      | 132 µs     | 151 µs     | 496 µs  | 299 µs   |

### Analysis

Comparing approaches at 10,000 iterations:

| Approach | Time | vs State/Nest | vs Monad/Nest | What it measures |
|----------|------|---------------|---------------|------------------|
| **State/Nest** (Freyja) | 2.44ms | 1x | 16x slower | Full Freer monad with effects |
| **Evf/Nest** (flat evidence) | 299µs | **8x faster** | 2x slower | Evidence map + state monad |
| **Ev/Nest** (nested evidence) | 496µs | 5x faster | 3x slower | Nested evidence map + state monad |
| **Monad/Nest** (simple state) | 151µs | 16x faster | 1x | Simple state monad, no dispatch |
| **Pure/Recur** (no abstraction) | 132µs | 18x faster | 0.9x | Direct recursion with map state |

### Key Insights

1. **Impure node allocation and handler matching account for ~8x of Freyja's overhead**

   The flat evidence-passing approach (`Evf/Nest`) achieves 8x speedup over Freyja while still supporting dynamic handler dispatch. This avoids:
   - `Sig` struct allocation for each effect operation
   - `Impure` node allocation wrapping the signature
   - Pattern matching through handler clauses
   - Continuation queue manipulation

2. **Dynamic dispatch adds ~2x overhead vs hardcoded handlers**

   The remaining gap between `Evf/Nest` (299µs) and `Monad/Nest` (151µs) is the cost of:
   - Map lookup for handler function (`env.state_get`)
   - Extra function call indirection (handler is a closure in the map)

3. **Nested vs flat evidence maps matters**

   Two-level map lookup (`Ev/Nest`) is ~1.7x slower than single-level (`Evf/Nest`). For a real implementation, using atoms like `:state_get` as flat keys would be preferable to nested `%{:state => %{:get => handler}}` structures.

4. **The state monad abstraction itself is nearly free**

   `Monad/Nest` (151µs) performs almost identically to `Pure/Recur` (132µs), showing that the `fn state -> {val, state}` pattern with nested binds adds minimal overhead.

### Implications

An evidence-passing implementation could provide **~8x speedup** over the current Freer approach while retaining dynamic handler composition. However, this would require:

1. **Different computation representation** - state monad style `fn env -> {val, env}` instead of `Pure`/`Impure` data structures
2. **Evidence threading** - passing the handler map through all computations
3. **Loss of inspectability** - computations become opaque functions, breaking effect logging and serialization

This represents a fundamental trade-off: evidence-passing sacrifices the data-structure representation that enables Freyja's effect logging, replay, and serialization features in exchange for performance.

For performance-critical code paths that don't need logging/replay, a hybrid approach could potentially offer the best of both worlds - but this would add significant complexity to the implementation.

---

## Skuld: A Real Evidence-Passing Implementation

### Background

Building on the hypothetical analysis above, we implemented **Skuld** - a complete evidence-passing algebraic effects library with CPS (continuation-passing style) to support control effects like Throw/Catch and Yield/Resume.

Skuld validates that evidence-passing can achieve significant performance improvements over Freyja while still supporting:
- Composable effect handlers
- Scoped handler installation
- Control effects (exceptions, coroutines)
- Higher-order effects (Catch, Local)

### Architecture

Skuld uses a simple, uniform CPS approach:

```elixir
# Computation type: fn env, resume -> outcome
@type computation :: (env(), resume() -> outcome())

# Handler type: fn args, env, resume -> outcome  
@type handler :: (term(), env(), resume() -> outcome())

# Outcome type: tagged union for control flow
@type outcome :: {:done, value, env} 
               | {:suspended, yielded, resume, env}
               | {:thrown, error, env}
```

Key differences from Freyja:
- **No Impure nodes** - effects invoke handlers directly via evidence map lookup
- **No continuation queues** - CPS chains continuations via closure nesting
- **Direct dispatch** - O(1) map lookup instead of protocol dispatch and pattern matching

### Benchmark Results

All times include both construction and execution (median of 5 runs):

| Target | Freyja (State/Nest) | Skuld/Nest | Speedup | Evf/Nest |
|--------|---------------------|------------|---------|----------|
| 500    | 143 µs              | 42 µs      | 3.4x    | 15 µs    |
| 1,000  | 258 µs              | 89 µs      | 2.9x    | 33 µs    |
| 2,000  | 512 µs              | 164 µs     | 3.1x    | 66 µs    |
| 5,000  | 1.25 ms             | 421 µs     | 3.0x    | 155 µs   |
| 10,000 | 2.61 ms             | 777 µs     | **3.4x**| 316 µs   |

### Analysis

1. **Skuld achieves ~3.4x speedup over Freyja** for State-heavy workloads, validating the evidence-passing approach.

2. **CPS overhead is ~2.5x vs bare evidence-passing** (`Evf/Nest`). This is the cost of supporting control effects - the `resume` continuation must be passed through every bind and handler call, even for simple effects that always resume immediately.

3. **Performance hierarchy at 10k iterations:**

   ```
   Pure/Recur    ~170 µs   (baseline - no abstraction)
   Monad/Nest    ~167 µs   (simple state monad)
   Evf/Nest      ~316 µs   (flat evidence, no control effects)
   Skuld/Nest    ~777 µs   (evidence + CPS for control effects)
   Freyja        ~2.61 ms  (Freer monad - full inspectability)
   ```

### Hybrid Plain/CPS Approach: Rejected

We explored a hybrid approach to reduce CPS overhead for simple effects:

- **Direct style** (arity-1): `fn env -> {value, env}` for State, Reader, Writer
- **CPS style** (arity-2): `fn env, resume -> outcome` for Throw, Yield

The hybrid would auto-detect computation arity via `is_function(comp, 1)` and lift direct computations to CPS when mixed with control effects.

**Results of hybrid approach:**

| Target | Full CPS | Hybrid | Improvement |
|--------|----------|--------|-------------|
| 500    | 57 µs    | 56 µs  | ~2%         |
| 1,000  | 118 µs   | 109 µs | ~8%         |
| 5,000  | 678 µs   | 540 µs | ~20%        |
| 10,000 | 1.13 ms  | 1.07 ms| ~5%         |

**The hybrid was rejected because:**

1. **Modest gains (5-20%)** don't justify the added complexity
2. **The real win is the 3.4x improvement** of evidence-passing over Freer - this dwarfs the hybrid's incremental gains
3. **Implementation simplicity** is valuable - the full CPS approach is ~200 lines of clean, uniform code
4. **Without static types**, we can't match Koka's optimizations - `is_function` checks at every bind add overhead that partially negates the direct-style savings

**Conclusion:** Control effects (Throw, Yield) are essential for practical effect systems. The CPS overhead to support them is acceptable. A 5-20% improvement is not worth the complexity of maintaining two execution modes in a dynamically-typed language.

### Trade-offs vs Freyja

| Feature | Freyja | Skuld |
|---------|--------|-------|
| Performance | 1x (baseline) | ~3.4x faster |
| Effect logging | ✅ Yes | ✅ Via handler interposition |
| Serializable effect logs | ✅ Yes | ✅ Yes |
| Cold replay from logs | ✅ Yes | ✅ Yes |
| Hot resume (in-memory) | ✅ Via continuation closures | ✅ Via continuation closures |
| Higher-order effects | ✅ Via hefty algebras | ✅ Via CPS scoping |
| Control effects | ✅ Via Freer | ✅ Via CPS outcomes |

Both approaches support effect logging and replay using the same fundamental technique: effect requests and responses are logged as serializable data, and cold replay re-runs the computation using logged responses to short-circuit effect execution. Hot resume (continuing a suspended computation in-memory) works via continuation closures in both systems - neither can serialize mid-execution state to disk.

Freyja's `Impure` nodes expose the current effect as inspectable data, but the continuation queue is opaque (a list of closures). Once effect logging is in place, both systems provide equivalent visibility into computation flow. **For practical purposes, Skuld offers ~3.4x better performance with equivalent functionality.**

---

## Running Benchmarks

```bash
# Queue benchmark (includes Skuld)
mix run bench/queue_benchmark.exs

# Flamegraph profiling
mix run bench/flamegraph_benchmark.exs
```
