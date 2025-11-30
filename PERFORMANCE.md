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

## Running Benchmarks

```bash
# Queue benchmark
mix run bench/queue_benchmark.exs

# Flamegraph profiling
mix run bench/flamegraph_benchmark.exs
```
