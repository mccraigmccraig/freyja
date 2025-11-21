# Freyja

[![Test](https://github.com/mccraigmccraig/freyja/actions/workflows/test.yml/badge.svg)](https://github.com/mccraigmccraig/freyja/actions/workflows/test.yml)
[![Hex.pm](https://img.shields.io/hexpm/v/freyja.svg)](https://hex.pm/packages/freyja)
[![Documentation](https://img.shields.io/badge/documentation-gray)](https://hexdocs.pm/freyja/)

**Algebraic Effects for Elixir**

---

## What is Freyja?

Freyja brings algebraic effects and handlers to Elixir, enabling you to write programs as pure functions that describe effects as data structures. These effects are then interpreted by handlers, providing a clean separation between **what** your program does (the effects) and **how** it does it (the handlers).

This separation enables powerful capabilities: the same program can be tested with mock handlers, run with different implementations in different environments, have all operations logged for audit trails, and even be replayed for debugging - all without changing the program code itself.

Freyja implements the **Hefty Algebras** architecture from [Poulsen & van der Rest (POPL 2023)](https://dl.acm.org/doi/10.1145/3571255), providing modular elaboration of higher-order effects through a two-phase execution model:

1. **Elaboration**: Transform higher-order effects into first-order effects
2. **Interpretation**: Execute first-order effects with handlers

This architecture makes complex effect interactions (like error handling with suspensions) work correctly by construction, without requiring special handling or workarounds.

---

## Quick Example

Here's a simple program showing error handling with the Hefty `catch` syntax:

```elixir
import Freyja.HeftyMacro
alias Freyja.Effects.{State, Throw, Catch}

defhefty safe_divide(a, b) do
  if b == 0 do
    Throw.throw_error(:division_by_zero)
  else
    return(a / b)
  end
catch
  :division_by_zero -> return(:infinity)
end

# Run it
outcome = Run.run(
  safe_divide(10, 0),
  [Catch.Algebra, Lift.Algebra],
  [Throw.Handler]
)

outcome.result  # => {:ok, :infinity}
```

The `catch` clause handles errors thrown during the computation, returning a fallback value. The error handling is compiled away during elaboration - no runtime overhead!

---

## Key Benefits

### 1. Testability

Swap handlers to test programs without real side effects:

```elixir
# Production: Real database
Run.run(program, [Storage.PostgresHandler], %{})

# Test: In-memory mock
Run.run(program, [Storage.MockHandler], %{mock_data: fixtures})
```

### 2. Clean Separation

Programs describe effects as pure data. Handlers interpret them:

```elixir
# Pure program - just describes what to do
defcon process_user(user_id) do
  user <- Storage.query(user_id)
  updated <- validate_and_update(user)
  _ <- Storage.save(updated)
  return(updated)
end

# Handler interprets effects (database, mock, logging, etc.)
```

### 3. Effect Composition

Higher-order effects compose cleanly with first-order effects:

```elixir
defhefty process_batch(items) do
  # Error handling (higher-order) + list processing + state
  results <- Catch.catch_hefty(
    FxList.fx_map(items, fn item ->
      hefty do
        count <- State.get()
        State.put(count + 1)
        Hefty.pure(process(item))
      end
    end),
    fn _err -> Hefty.pure([]) end  # Fallback on error
  )

  return(results)
end
```

Error handling, list processing, and state management compose without interference.

### 4. Suspensions Work Correctly

Computations can suspend and resume, even inside error handlers:

```elixir
defhefty process_with_checkpoints(data) do
  Catch.catch_hefty(
    hefty do
      x <- Coroutine.yield(data)  # Suspend (auto-lifted)
      # After resume, still inside catch scope!
      if x < 0 do
        Throw.throw_error(:negative)  # Auto-lifted, short-circuits
      else
        return(x * 2)
      end
    end,
    fn _err -> Hefty.pure(0) end
  )
end
```

The catch scope is preserved across suspensions - errors after resume are still caught!

### 5. Auditability

Effect operations are data structures that can be logged:

```elixir
# Log all effects during execution
outcome = EffectLogger.run_with_log(computation, handlers)

# Replay later for debugging
replayed = EffectLogger.replay(outcome.log, handlers)
```

Complete audit trail with deterministic replay.

---

## Core Concepts

### First-Order vs Higher-Order Effects

**First-order effects** are simple operations:
- `State.get()` - read state
- `Writer.tell("log")` - write log
- `Storage.query(id)` - query database

**Higher-order effects** take computations as parameters:
- `Catch.catch_hefty(try_block, error_handler)` - error handling
- `TaggedWriter.listen(computation)` - capture logs during computation
- `FxList.fx_map(list, fn -> computation end)` - effectful map

### The `con` and `hefty` Macros

Use `con` for first-order effects only:

```elixir
defcon simple_example do
  x <- State.get()
  _ <- Writer.tell("Got: #{x}")
  _ <- State.put(x + 1)
  return(x + 1)
end
```

Use `hefty` when you need higher-order effects:

```elixir
defhefty with_error_handling do
  Catch.catch_hefty(
    hefty do
      x <- State.get()  # First-order, auto-lifted to Hefty

      if x < 0 do
        Throw.throw_error(:negative)  # Auto-lifted, short-circuits
      else
        return(x)
      end
    end,
    fn _err -> Hefty.pure(0) end
  )
end
```

First-order effects are automatically lifted to Hefty when used in `hefty` blocks.

### Two-Phase Execution

Hefty computations execute in two phases:

```elixir
Run.run(
  computation,
  [Catch.Algebra, Lift.Algebra],  # Phase 1: Elaboration
  [State.Handler, Throw.Handler],  # Phase 2: Interpretation
  %{State.Handler => 0}             # Initial states
)
```

**Phase 1 (Elaboration)**: Algebras transform higher-order effects into first-order effects
- `Catch.catch_hefty` → structural transformation using interposition
- `TaggedWriter.listen` → PeekAll queries before/after
- Result: Pure first-order computation

**Phase 2 (Interpretation)**: Handlers execute first-order effects
- Single top-level interpreter
- All effects at same level
- Suspensions work correctly

---

## Available Effects

### First-Order Effects

These are simple operations interpreted by handlers:

#### State Management
- **`State`** - Single mutable state
  ```elixir
  x <- State.get()            # Read current state
  _ <- State.put(value)       # Replace state
  _ <- State.update(fn)       # Transform state
  ```

- **`TaggedState`** - Multiple independent states by tag
  ```elixir
  count <- TaggedState.get(:user_count)
  _ <- TaggedState.put(:user_count, 42)
  ```

#### Environment/Context
- **`Reader`** - Read-only environment
  ```elixir
  config <- Reader.ask()  # Get environment value
  ```

- **`TaggedReader`** - Multiple environments by tag
  ```elixir
  config <- TaggedReader.ask(:config)
  secrets <- TaggedReader.ask(:secrets)
  ```

#### Logging/Output
- **`Writer`** - Accumulate output
  ```elixir
  _ <- Writer.tell("message") # Append to log
  ```

- **`TaggedWriter`** - Multiple output streams by tag
  ```elixir
  _ <- TaggedWriter.tell(:audit, event)
  _ <- TaggedWriter.tell(:metrics, data)
  logs <- TaggedWriter.peek(:audit)     # Query current logs
  all_logs <- TaggedWriter.peek_all()   # Query all tag logs
  ```

#### Error Handling
- **`Throw`** - Throw errors (first-order operation)
  ```elixir
  _ <- Throw.throw_error(reason)  # Short-circuit with error
  ```

#### Control Flow
- **`Coroutine`** - Suspend and resume
  ```elixir
  result <- Coroutine.yield(value)  # Suspend with value
  # Resumed later with Run.resume(outcome, input)
  ```

### Higher-Order Effects

These take computations as parameters and are elaborated away:

#### Error Handling
- **`Catch.catch_hefty`** - Exception handling with scopes
  ```elixir
  Catch.catch_hefty(
    try_computation,
    fn error -> recovery_computation end
  )
  ```

  Or use the `catch` clause syntax:
  ```elixir
  hefty do
    # computation that might throw
  catch
    :not_found -> return(:default)
    :timeout -> return(:retry)
  end
  ```

#### Log Capture
- **`TaggedWriter.listen`** - Capture logs during computation
  ```elixir
  {result, logs} <- TaggedWriter.listen(
    hefty do
      TaggedWriter.tell(:audit, "event1")
      TaggedWriter.tell(:debug, "event2")
      return(42)
    end
  )
  # logs => %{audit: ["event1"], debug: ["event2"]}
  ```

#### List Processing
- **`FxList.fx_map`** - Map with effects
  ```elixir
  results <- FxList.fx_map([1, 2, 3], fn x ->
    hefty do
      State.update(&(&1 + x))
      return(x * 2)
    end
  end)
  ```

---

## Real-World Example

Here's a complete example showing change tracking with bulk updates:

```elixir
import Freyja.HeftyMacro
alias Freyja.Effects.{State, Throw, Catch, TaggedWriter, FxList}

# Define custom Storage effect
defmodule Storage do
  import Freyja.Freer.Sig.DefEffectStruct
  import Freyja.Hefty.Sig.DefHeftyStruct

  # First-order operations
  def_effect_struct(Query, ids: [])
  def_effect_struct(Change, old: nil, new: nil)
  def_effect_struct(UpdateAll, changes: [])

  # Higher-order operation
  def_hefty_struct(ApplyAllChanges, [])

  def query(ids), do: %Query{ids: ids}
  def change(old, new), do: %Change{old: old, new: new}
  def update_all(changes), do: %UpdateAll{changes: changes}

  def apply_all_changes(computation) do
    Freyja.Hefty.send_hefty(__MODULE__, %ApplyAllChanges{}, %{inner: computation})
  end
end

# The Storage.ApplyAllChanges algebra uses TaggedWriter.listen to capture changes:
defmodule Storage.Algebra do
  def elaborate(%ApplyAllChanges{}, psi, k, _elaborator) do
    inner_comp = Map.fetch!(psi, :inner)

    con do
      # Capture changes during computation
      initial_logs <- TaggedWriter.peek_all()
      result <- inner_comp
      final_logs <- TaggedWriter.peek_all()

      captured = calculate_diff(initial_logs, final_logs)
      changes = captured[:changes] || []

      # Apply all changes in bulk
      _count <- Storage.update_all(changes)

      k.({result, captured})
    end
  end
end

# Business logic - pure, declarative
defhefty process_users(user_ids) do
  users <- Storage.query(user_ids)  # Auto-lifted

  # Process with automatic change tracking
  {updated, logs} <- Storage.apply_all_changes(
    FxList.fx_map(users, fn user ->
      hefty do
        # Remove email and track change
        updated = Map.delete(user, :email)
        Storage.change(user, updated)  # Auto-lifted

        # Track count in State
        State.update(&(&1 + 1))  # Auto-lifted

        return(updated)
      end
    end)
  )

  count <- State.get()  # Auto-lifted

  return(%{
    users: updated,
    changes: length(logs[:changes] || []),
    count: count
  })
end

# Run with handlers
outcome = Run.run(
  process_users([1, 2, 3]),
  [Storage.Algebra, FxList.Algebra, Lift.Algebra],  # Elaboration
  [Storage.Handler, TaggedWriter.Handler, State.Handler],  # Interpretation
  %{State.Handler => 0}
)
```

Full example: [`lib/freyja/examples/hefty_change_capture.ex`](https://github.com/mccraigmccraig/freyja/blob/main/lib/freyja/examples/hefty_change_capture.ex)

---

## How It Works: Two-Phase Architecture

Freyja uses a two-phase execution model based on Hefty Algebras:

### Phase 1: Elaboration (Higher-Order → First-Order)

Algebras transform higher-order effects into first-order effects:

```elixir
# Before elaboration (Hefty):
Catch.catch_hefty(
  hefty do
    Throw.throw_error(:oops)  # Auto-lifted
  end,
  fn _err -> Hefty.pure(:recovered) end
)

# After elaboration (Freer):
# The Throw operation is intercepted and replaced with :recovered
# All at the same level - no nested interpretation
Freer.pure(:recovered)
```

Algebras use **interposition** to structurally transform computations:
- Walk the computation tree recursively
- Intercept specific operations (like Throw)
- Replace them with handler results
- Preserve structure (suspensions work correctly!)

### Phase 2: Interpretation (First-Order → Results)

A single top-level interpreter executes first-order effects:

```elixir
# Handlers interpret effects one by one
x <- State.get()           # → read from handler state
_ <- Writer.tell("log")    # → append to handler state
v <- Coroutine.yield(val)  # → return suspension
```

All effects are at the same level, so they compose without conflicts.

### Why This Matters

**Old approach** (runner effects): Higher-order effects would call nested `Run.run()`:
- Created separate interpreter contexts
- Lost scope when suspensions occurred
- Required complex state propagation (ScopedOk)
- Didn't compose well

**New approach** (interposition): Higher-order effects transform the structure:
- Single top-level interpreter
- Suspensions preserve all scopes
- State flows naturally
- Composes perfectly

Example - this **just works**:
```elixir
# Catch + Yield - suspension preserves catch scope
defhefty example do
  Catch.catch_hefty(
    hefty do
      x <- Coroutine.yield(5)  # Suspend! (auto-lifted)
      # After resume, still inside catch scope
      if x < 0 do
        Throw.throw_error(:negative)  # Auto-lifted, short-circuits
      else
        return(x)
      end
    end,
    fn _err -> Hefty.pure(0) end
  )
end

# Works correctly - catch scope preserved after resume!
```

---

## Getting Started

### Basic First-Order Effects

Start with simple effects using the `con` macro:

```elixir
import Freyja.Con
alias Freyja.Effects.{State, Writer}

defcon calculate_sum(a, b) do
  _ <- Writer.tell("Calculating sum")

  # Get multiplier from state
  multiplier <- State.get()

  # Calculate result
  result = (a + b) * multiplier

  # Update state with result
  _ <- State.put(result)

  # Log the result
  _ <- Writer.tell("Result: #{result}")

  return(result)
end

# Run it
outcome = Run.run(
  calculate_sum(10, 5),
  [State.Handler, Writer.Handler],
  %{State.Handler => 2}
)

outcome.result  # => 30 (15 * 2)
outcome.outputs[State.Handler]   # => 30
outcome.outputs[Writer.Handler]  # => ["Result: 30", "Calculating sum"]
```

### Adding Error Handling

Use `hefty` with `Catch` for error handling:

```elixir
import Freyja.HeftyMacro
alias Freyja.Effects.{Catch, Throw}

defhefty fetch_user(id) do
  Catch.catch_hefty(
    hefty do
      Database.get(id)  # Auto-lifted
    end,
    fn
      :not_found -> Hefty.pure(:guest_user)
      error -> Hefty.pure({:error, error})
    end
  )
end

# Or use catch clause syntax (cleaner):
defhefty fetch_user_v2(id) do
  Database.get(id)  # Auto-lifted
catch
  :not_found -> return(:guest_user)
  error -> return({:error, error})
end
```

### Composing Multiple Effects

Effects compose naturally:

```elixir
defhefty process_with_logging(items) do
  # Capture logs from processing
  {results, logs} <- TaggedWriter.listen(
    FxList.fx_map(items, fn item ->
      hefty do
        _ <- TaggedWriter.tell(:audit, {:processing, item})
        result <- process_item(item)
        _ <- TaggedWriter.tell(:audit, {:processed, result})
        return(result)
      end
    end)
  )

  # Save audit log (auto-lifted)
  _ <- save_audit_log(logs[:audit])

  return(results)
end
```

---

## Architecture Overview

### The Freer Monad

First-order effects use the Freer monad:

```elixir
# An effect is data + continuation
%Freyja.Freer.Impure{
  sig: State,                    # Effect signature
  data: %State.Get{},            # Operation data
  q: [continuation_function]     # What to do with result
}

# A pure value (no more effects)
%Freyja.Freer.Pure{val: 42}
```

Programs build up a tree of effects and continuations. Handlers interpret them one by one.

### The Hefty Monad

Higher-order effects use the Hefty monad:

```elixir
# A higher-order operation with computation parameters
%Freyja.Hefty.Impure{
  sig: Catch,
  data: %Catch{handler: error_handler_fn},
  psi: %{try: try_computation},    # Computation parameters!
  k: continuation
}
```

The key difference: `psi` contains **other computations** as parameters.

### Elaboration with Interposition

Algebras elaborate higher-order effects using **interposition** - a structural transformation that:

1. Walks the computation tree recursively
2. Intercepts specific operations (e.g., Throw)
3. Replaces them with handler results
4. Preserves structure for non-matching effects

This is why suspensions work - the transformation is baked into the structure!

Example - how `Catch` elaborates:

```elixir
# Catch.Algebra.elaborate uses interposition
Interpose.interpose_with(
  try_comp,
  fn sig, data -> sig == Throw and match?(%ThrowOp{}, data) end,
  fn %ThrowOp{error: err}, _continuation ->
    # When Throw encountered: run error handler, DON'T call continuation
    # This is how throw short-circuits!
    error_handler_fn.(err) |> elaborate()
  end
)
```

When the computation suspends (Coroutine.yield), the Throw interception is preserved in the continuation. Resume works correctly!

---

## Examples

### Change Tracking with Bulk Updates

See [`lib/freyja/examples/hefty_change_capture.ex`](https://github.com/mccraigmccraig/freyja/blob/main/lib/freyja/examples/hefty_change_capture.ex) for a complete example showing:
- Custom Storage effect with higher-order `apply_all_changes`
- Using `TaggedWriter.listen` to capture changes
- Composing with `FxList.fx_map` for batch processing
- Automatic change tracking without manual plumbing

### Error Handling Examples

See [`test/freyja/hefty_macro_test.exs`](https://github.com/mccraigmccraig/freyja/blob/main/test/freyja/hefty_macro_test.exs) for comprehensive error handling patterns:
- Pattern matching in catch clauses
- Nested error handlers
- Error handling with state effects
- Catch with suspensions

### Suspension and Resumption

See [`test/freyja/effects/scoped_test.exs`](https://github.com/mccraigmccraig/freyja/blob/main/test/freyja/effects/scoped_test.exs) for examples of:
- Suspending inside error handlers
- Resuming with catch scope preserved
- Multiple suspensions with complex effect stacks

---

## Running Computations

### Freer Computations (First-Order Only)

```elixir
import Freyja.Con

computation = con do
  x <- State.get()
  _ <- Writer.tell("Value: #{x}")
  _ <- State.put(x + 1)
  return(x)
end

outcome = Run.run(
  computation,
  [State.Handler, Writer.Handler],
  %{State.Handler => 0}
)
```

### Hefty Computations (With Higher-Order Effects)

```elixir
import Freyja.HeftyMacro

computation = hefty do
  Catch.catch_hefty(
    hefty do
      State.get()  # Auto-lifted
    end,
    fn _err -> Hefty.pure(0) end
  )
end

outcome = Run.run(
  computation,
  [Catch.Algebra, Lift.Algebra],  # Algebras for elaboration
  [State.Handler, Throw.Handler],  # Handlers for interpretation
  %{State.Handler => 42}
)
```

### Handling Suspensions

```elixir
# Initial run - might suspend
outcome = Run.run(computation, handlers, initial_states)

# Check if suspended
case outcome.result do
  {:suspend, value, continuation} ->
    # Resume with input
    next_outcome = Run.resume(outcome, input_value)
    # May suspend again or complete

  final_result ->
    # Computation completed
    IO.puts("Result: #{inspect(final_result)}")
end
```

---

## Advanced Features

### Effect Logging and Replay

Log all effect operations for audit trails and debugging:

```elixir
# Run with logging
outcome = Run.run(
  computation,
  algebras,
  [EffectLogger.Handler | other_handlers],
  initial_states
)

# Log contains all effect operations
log = outcome.outputs[EffectLogger.Handler]

# Replay for debugging (uses logged values)
replayed = EffectLogger.replay(log, handlers)
```

### Tagged Effects for Multiple Instances

Use tagged effects to manage multiple independent instances:

```elixir
# Multiple state cells
con do
  user_count <- TaggedState.get(:users)
  post_count <- TaggedState.get(:posts)

  _ <- TaggedState.put(:users, user_count + 1)

  return({user_count, post_count})
end

# Multiple log streams
con do
  _ <- TaggedWriter.tell(:audit, %{action: :login})
  _ <- TaggedWriter.tell(:metrics, %{event: :user_active})
  _ <- TaggedWriter.tell(:debug, "Processing...")

  return(:ok)
end
```

### Custom Effects

Define your own effects:

```elixir
# 1. Define effect operations
defmodule Http do
  import Freyja.Freer.Sig.DefEffectStruct

  def_effect_struct(Get, url: nil)
  def_effect_struct(Post, url: nil, body: nil)

  def get(url), do: %Get{url: url}
  def post(url, body), do: %Post{url: url, body: body}
end

# 2. Implement handler
defmodule Http.Handler do
  @behaviour Freyja.EffectHandler

  def handles?(%Impure{sig: Http}, _state), do: true
  def handles?(_, _), do: false

  def interpret(%Impure{sig: Http, data: op, q: q}, _key, state, _run_state) do
    result = case op do
      %Http.Get{url: url} -> HTTPoison.get(url)
      %Http.Post{url: url, body: body} -> HTTPoison.post(url, body)
    end

    {Impl.q_apply(q, result), state}
  end
end

# 3. Use it
defcon fetch_data(url) do
  response <- Http.get(url)
  return(response.body)
end
```

For higher-order effects, implement an Algebra - see existing algebras for patterns.

---

## Documentation

- **MCP Integration**: [`MCP_EFFECTS_2.md`](https://github.com/mccraigmccraig/freyja/blob/main/MCP_EFFECTS_2.md) - LLM agent integration
- **Architecture**: Module docs in `lib/freyja/` explain implementation details
- **Examples**: [`lib/freyja/examples/`](lib/freyja/examples/) - Real-world patterns
- **Tests**: [`test/freyja/`](test/) - Comprehensive usage examples

---

## Implementation Notes

### Interposition-Based Elaboration

Freyja uses interposition (from Heftia) for elaborating higher-order effects. This provides:
- Sound composition (no scope loss)
- Correct suspension handling
- Single top-level interpreter
- O(H + S) complexity instead of O(H × S)

See [`lib/freyja/freer/interpose.ex`](https://github.com/mccraigmccraig/freyja/blob/main/lib/freyja/freer/interpose.ex) for the implementation.

### No Special Cases

Unlike many effect systems, Freyja has no special cases for:
- Error handling + suspensions (works automatically)
- Nested higher-order effects (pure composition)
- State propagation (flows through single interpreter)
- Multiple effect types interacting (all at same level)

This simplicity comes from the Hefty Algebras architecture.

---

## Installation

Add `freyja` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:freyja, "~> 0.1.0"}
  ]
end
```

---

## Contributing

Contributions are welcome! Please feel free to open issues or submit pull requests.

Key areas for contribution:
- Additional effect implementations
- Performance optimizations
- Documentation improvements
- Example applications

---

## References

- **Hefty Algebras Paper**: [Poulsen & van der Rest (POPL 2023)](https://dl.acm.org/doi/10.1145/3571255)
- **Heftia (Haskell)**: [sayo-hs/heftia](https://github.com/sayo-hs/heftia) - Reference implementation
- **Algebraic Effects Overview**: [What is algebraic about algebraic effects?](https://arxiv.org/abs/1807.05923)
- **Freer Monads, More Extensible Effects**: [Kiselyov & Ishii](https://okmij.org/ftp/Haskell/extensible/more.pdf)
- **freer-simple — a friendly effect system for Haskell**: [lexi-lambda/freer-simple](https://github.com/lexi-lambda/freer-simple)
  


---

## License

[MIT License](LICENSE)
