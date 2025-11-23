# Freyja

## What is Freyja?

Freyja is an Algebraic Effects system for Elixir, enabling you to write programs as pure functions that describe all their side effects as "effect" data structures. These effects are then interpreted by handlers, providing a clean separation between **what** your program does (the effects) and **how** it does it (the handlers).

## 1. What are Algebraic Effects?

Algebraic effects are plain data structures that describe something impure you want
your program to do. Instead of performing I/O, mutating state, or throwing errors
directly, a function can **return** an effect value such as “read the current
state” or “write this log message”.

An algebraic effect system such as **Freyja** lets you build programs whose domain
logic lives entirely in pure functions that emit these effect values. Separate
**handlers** interpret the emitted data structures and decide how (or whether) to
carry out the effects.

This separation has several benefits:

- **Composability** – swap or stack handlers to change behavior (e.g., real DB vs.
  in-memory mock).
- **Testability** – pure functions are easy to unit test; handlers can log or
  replay effects deterministically.
- **Replay & Debugging** – since effects are first-class data, they can be logged,
  serialized, and replayed later, even on a different machine.

In short: describe your intentions as data, keep your business logic pure, and let
Freyja orchestrate how and when effects run.

_Further reading:_ [“What is Algebraic about Algebraic Effects?”](https://interjectedfuture.com/what-is-algebraic-about-algebraic-effects/)
offers a gentle introduction to why they are called Algebraic Effects.

### 1.1 A real effect: Tagged State

Freyja is bundled with a number of Effects and Handlers - `TaggedState` is one
one of them - it allows access to "mutable" state cells - from anywhere
inside your nested pure functions, without having to add extra parameters to 
your function signatures

```elixir
# TaggedState: get/put state associated with a tag
defmodule Freyja.Effects.TaggedState.GetTagged do
  defstruct [:tag]
end

defmodule Freyja.Effects.TaggedState.PutTagged do
  defstruct [:tag, :value]
end

defmodule Freyja.Effects.TaggedState do
  def get(tag), do: %GetTagged{tag: tag}
  def put(tag, value), do: %PutTagged{tag: tag, value: value}
end
```
The constructor functions like `get(tag)`, and `put(tag, value)`will build
the structs for you, but you can also build them direcetly without any
loss of function:

```elixir
%Freyja.Effects.TaggedState.GetTagged{tag: :cart}
%Freyja.Effects.TaggedState.PutTagged{tag: :cart, value: [:item_a, :item_b]}
```

They’re just plain data. Handlers decide exactly what to do with them — read
from ETS, append to a log, store in a map, or something else entirely.

### 1.2 Define Your Own Effect Language

Most applications invent their own “impure verbs”. With Freyja you can codify
those verbs as effect structs instead of performing side effects immediately.

```elixir
# Domain-specific storage effect
defmodule MyApp.Storage.Query do
  defstruct [:table, :id]
end

defmodule MyApp.Storage.Change do
  defstruct [:table, :record]
end

defmodule MyApp.Storage do
  def query(table, id), do: %Query{table: table, id: id}
  def change(table, record), do: %Change{table: table, record: record}
end

# Domain-specific notification effect
defmodule MyApp.Notifications.SendPush do
  defstruct [:user_id, :message]
end

defmodule MyApp.Notifications do
  def send_push(user_id, message), do: %SendPush{user_id: user_id, message: message}
end
```

Your pure business logic can now “describe” what it needs. The `con` macro
helps you compose effectful computations using a familiar `with`-like syntax:

```elixir
def checkout(cart, user) do
  con do
    product <- MyApp.Storage.query(:products, cart.product_id)

    if user.credit < product.price do
      Throw.throw_error(:insufficient_credit)
    else
      con do 
        updated_user = %{user | credit: user.credit - product.price}
        _ <- MyApp.Storage.change(:users, updated_user)
        _ <- MyApp.Notifications.send_push(user.id, "Thanks for buying #{product.name}!")
        return({:ok, updated_user})
      end
    end
  end
end
```

At this point, `checkout/2` is entirely pure—it only has pure domain logic and
emits effect structs, while handlers will decide how to interpret them: hitting
real services, wrapping DB access in transactions, or using mocks in tests.

```elixir
case checkout(cart, user)
     |> MyApp.Storage.PostgreSQLHandler.run(db_connection)
     |> MyApp.Notifications.PigeonHandler.run(push_adapter)
     |> Throw.Handler.run()
     # eval returns only the result - run will return the full context
     |> Run.eval() do
  {:ok, updated_user} ->
    IO.inspect(updated_user, label: "User debited")

  {:error, :insufficient_credit} ->
    Logger.warn("Not enough credit")

  {:error, reason} ->
    Logger.error("Checkout failed: #{inspect(reason)}")
end
```

This illustrates how Freyja lets your domain logic stay pure while the handlers
deal with the impure plumbing.

## 2. A Quick Tour: A short list of some cool things Algebraic Effects enable

Not nearly an exhaustive list, but there are IEx runnable examples for each case!

### 2.1 Coroutine-Based Programming

From the IEx runnable  [`command_processor.ex`](https://github.com/mccraigmccraig/freyja/blob/main/lib/freyja/examples/command_processor.ex)
example:

A Coroutine effect let you suspend and resume computations. Domain logic
can be completely agnostic about how responses are gathered—interactive UI, CLI
prompts, LLMs, or batch pipelines can all drive the same pure core.

Since effects are just simple data-structures you can use your effects as
commands - and your whole system becomes command-driven with little effort.

Here's a simple coroutine-based command processor which repeatedly suspends,
asking for the next command. You can feed it commands from a UI or CLI or, since
your commands are just easily documented strucs, you can have an LLM
build commands and AI enable your whole app for free:

```elixir
defcon loop do
  # yield to outside the computation to ask for the next command
  command <- Coroutine.yield(:next_command)

  case command do
    %Storage.Query{} = effect ->
      handle_effect(effect)

    %Storage.Change{} = effect ->
      handle_effect(effect)

    %Notifications.SendPush{} = effect ->
      handle_effect(effect)

    :stop ->
      return(:stopped)

    other ->
      Throw.throw_error({:unknown_command, other})
  end
end

defconp handle_effect(effect) do
  _ <- effect
  loop()
end

# provide handlers for all the effects
builder = Freyja.Examples.CommandProcessor.builder()
# run the computation up to the yield
processor = Freyja.Run.run(builder)

commands = [
  Storage.query(:products, "A1"),
  Storage.change(:users, %{id: 1, name: "Ann"}),
  Notifications.send_push(1, "Hello!"),
  :stop
]
# repeatedly resume the computation with successive commands/effects
final_outcome = Enum.reduce(commands, processor, fn cmd, outcome ->
  Freyja.Run.resume(builder, outcome, cmd)
end)

```

Because commands are just effect structs, you can whitelist them for MCP tooling,
log them, or feed them manually—no extra glue code required.

### 2.2 EffectLogger: Log, Replay, and Resume Anything

#### (a) Automatic Log Collection

By inserting `EffectLogger.Handler.run/1` at the start of the Handler 
pipeline, you get full logs of every effect emitted—perfect for audit, 
tracing, or offline debugging.

```elixir
outcome =
  con do
    old_state <- State.put(10)
    return(old_state)
  end
  |> EffectLogger.Handler.run(EffectLogger.Log.new())
  |> State.Handler.run(5)
  |> Run.run()

IO.inspect(outcome, pretty: true)
```

Example output (abridged):

```elixir
%RunOutcome{
  result: 5,
  outputs: %{
    EffectLogger.Handler => %EffectLogger.Log{
      stack: [],
      queue: [
        %StepLogEntry{
          effects_stack: [],
          effects_queue: [
            %EffectLogEntry{sig: Freyja.Effects.State, data: %State.Put{val: 10}}
          ],
          completed?: true,
          value: 5
        }
      ],
      replay_allow_final_divergence?: false
    }
  }
}
```

#### (b) Rerun to Debug (Even After Serialization)

```elixir
builder =
  computation
  |> EffectLogger.Handler.run(log)
  |> State.Handler.run(0)

outcome = builder |> Run.run()

# Later: fix the code and rerun using the captured log
json = Jason.encode!(outcome)
decoded = Jason.decode!(json)

debug_outcome = Run.rerun(builder, decoded)
```

`Run.rerun/2` will run the computation from "cold" logs (even after JSON
serialization) and automatically enables “allow divergence” so you can step past
the original error. Try it live with
[`Freyja.Examples.EffectLoggerRerun`](https://github.com/mccraigmccraig/freyja/blob/main/lib/freyja/examples/effect_logger_rerun.ex):

```
buggy = Freyja.Examples.EffectLoggerRerun.build(:original)
json = buggy |> Run.run() |> Jason.encode!()

fixed = Freyja.Examples.EffectLoggerRerun.build(:patched)
Run.rerun(fixed, Jason.decode!(json))
```

#### (c) Cold Resume from Logs

```elixir
{:suspend, prompt, _} = outcome.result
checkpoint = Jason.encode!(outcome)

# Later
decoded_checkpoint = Jason.decode!(checkpoint)
resumed = Run.resume(builder, decoded_checkpoint, :new_value)
```

EffectLogger’s serialized state is also enough to "cold" resume a coroutine from
deserialized logs, even though the original continuation has been lost! See
[`Freyja.Examples.EffectLoggerResume`](https://github.com/mccraigmccraig/freyja/blob/main/lib/freyja/examples/effect_logger_resume.ex)
for a copy/pasteable builder demonstrating the pattern in IEx.

### 2.3 Change Capture: TaggedWriter + Hefty Algebra

From the IEx runnable [`change_capture.ex`](https://github.com/mccraigmccraig/freyja/blob/main/lib/freyja/examples/change_capture.ex)
exmple here is a trimmed down snippet showing how TaggedWriter, State, and Hefty 
algebras (see below) work together:

```elixir
defmodule Storage do
  import Freyja.Freer.Sig.DefEffectStruct
  import Freyja.Hefty.Sig.DefHeftyStruct

  def_effect_struct(Query, ids: [])
  def_effect_struct(Change, old: nil, new: nil)
  def_effect_struct(UpdateAll, changes: [])
  def_hefty_struct(ApplyAllChanges, [])

  def query(ids), do: %Query{ids: ids}
  def change(old, new), do: %Change{old: old, new: new}
  def update_all(changes), do: %UpdateAll{changes: changes}

  def apply_all_changes(computation) do
    Freyja.Hefty.send_hefty(__MODULE__, %ApplyAllChanges{}, %{inner: computation})
  end
end

defhefty process_users(ids, process_user_fn) do
  users <- Storage.query(ids)
  {updated_users, logs} <- Storage.apply_all_changes(FxList.fx_map(users, process_user_fn))
  count <- State.get()
  return(%{updated_users: updated_users, all_logs: logs, processed_count: count})
end
```

Each processing function (e.g., `remove_email_from_user/1`) can call
`Storage.change/2`, `TaggedWriter.tell/2`, or throw errors without changing
`process_users/2`.

## 3. Core Concepts

### First-Order vs Higher-Order Effects

**First-order effects** are simple operations, which do not take computatinos
as parameters:
- `State.get()` - read state
- `Writer.tell("log")` - write log
- `Storage.query(id)` - query database

**Higher-order effects** take other computations as parameters:
- `Catch.catch_hefty(try_block, error_handler)` - error handling
- `TaggedWriter.listen(computation)` - capture logs during computation
- `FxList.fx_map(list, fn -> computation end)` - effectful map

### The `con` and `hefty` Macros

`con` and `hefty` are macro sugar which can be used to compose effectful
functions, using a familiar `with`-like syntax.

Each step in a `con` or `hefty` binds a value, apart from the last step which
**returns** an effect

* `<-` steps are effectfful - the right-hand side must be an effectful function
* `=` steps are normal Elixir pattern-matches

Use `con` for blocks composing first-order effects only, and `defcon` for
functions whose body composes first-order effects:

```elixir
defcon simple_example do
  x <- State.get()
  y = x + 1
  _ <- Writer.tell("Got: #{x}")
  _ <- State.put(y)
  return(x + 1)
end
```

Use `hefty` when you need to use higher-order effects - `hefty` also
allows first-order effects: it's only distinct from `con` because it adds
some overhead, so `con` is more efficient. `defhefy` defines a function
with a `hefty` body:

```elixir
defhefty with_error_handling do
  Catch.catch_hefty(
    hefty do
      x <- State.get()  # First-order, auto-lifted to Hefty
      y = x + 1

      if x < 0 do
        Throw.throw_error(:negative)  # Auto-lifted, short-circuits
      else
        return(y)
      end
    end,
    fn _err -> Hefty.pure(0) end
  )
end
```

(First-order effects are automatically lifted to Hefty when used in `hefty` blocks)

### Two-Phase Execution

Hefty computations execute in two phases:

```elixir
outcome = computation
  |> Catch.Algebra.run()   # Phase 1: Elaboration
  |> Lift.Algebra.run()    # Phase 1: Elaboration
  |> State.Handler.run(0)  # Phase 2: Interpretation
  |> Throw.Handler.run()   # Phase 2: Interpretation
  |> Run.run()             # Execute!
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

## 4. How It Works: Two-Phase Architecture

Freyja uses a two-phase execution model based on Hefty Algebras (see references
below):

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

## 5. Bundled Effects

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
  # Resumed later with Run.resume(builder, outcome, input)
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

## 6. Getting Started

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

# Run it with pipe API
outcome = calculate_sum(10, 5)
  |> State.Handler.run(2)
  |> Writer.Handler.run()
  |> Run.run()

outcome.result  # => 30 (15 * 2)
outcome.outputs[State.Handler]   # => 30
outcome.outputs[Writer.Handler]  # => ["Result: 30", "Calculating sum"]
```

### Adding Error Handling

Use `hefty` with `Catch` for error handling:

```elixir
import Freyja.HeftyMacro
alias Freyja.Effects.{Catch, Lift, Throw}

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

# Or use the cleaner catch-clause syntax
defhefty fetch_user_v2(id) do
  Database.get(id)  # Auto-lifted
catch
  :not_found -> return(:guest_user)
  error -> return({:error, error})
end

# Run with pipe API
outcome = fetch_user_v2(123)
  |> Catch.Algebra.run()
  |> Lift.Algebra.run()
  |> Database.Handler.run(db_config)
  |> Throw.Handler.run()
  |> Run.run()
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

## 7. Diving deeper

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

## Running Computations

### Freer Computations (First-Order Only)

```elixir
use Freyja.Syntax
alias Freyja.Effects.{State, Writer}

computation = con do
  x <- State.get()
  _ <- Writer.tell("Value: #{x}")
  _ <- State.put(x + 1)
  return(x)
end

# Run with pipe API
outcome = computation
  |> State.Handler.run(0)
  |> Writer.Handler.run()
  |> Run.run()

# Or just get the result
result = computation
  |> State.Handler.run(0)
  |> Writer.Handler.run()
  |> Run.eval()  # => 0
```

### Hefty Computations (With Higher-Order Effects)

```elixir
use Freyja.Syntax
alias Freyja.Effects.{Catch, Lift, State, Throw}

computation = hefty do
  Catch.catch_hefty(
    hefty do
      State.get()  # Auto-lifted
    end,
    fn _err -> Hefty.pure(0) end
  )
end

# Run with pipe API - algebras first, then handlers
outcome = computation
  |> Catch.Algebra.run()
  |> Lift.Algebra.run()
  |> State.Handler.run(42)
  |> Throw.Handler.run()
  |> Run.run()
```

### Handling Suspensions

```elixir
# Initial run - might suspend
builder =
  computation
  |> Coroutine.Handler.run()
  |> State.Handler.run(0)

outcome = builder |> Run.run()

# Check if suspended
case outcome.result do
  {:suspend, value, _continuation} ->
    # Resume with input (works for live or serialized outcomes)
    next_outcome = Run.resume(builder, outcome, input_value)
    # May suspend again or complete

  final_result ->
    # Computation completed
    IO.puts("Result: #{inspect(final_result)}")
end
```

### Define your own effects

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
- **Heftia (Haskell)**: [sayo-hs/heftia](https://github.com/sayo-hs/heftia)
- **Algebraic Effects Overview**: [What is algebraic about algebraic effects?](https://arxiv.org/abs/1807.05923)
- **Freer Monads, More Extensible Effects**: [Kiselyov & Ishii](https://okmij.org/ftp/Haskell/extensible/more.pdf)
- **freer-simple — a friendly effect system for Haskell**: [lexi-lambda/freer-simple](https://github.com/lexi-lambda/freer-simple)

---

## License

[MIT License](LICENSE)
