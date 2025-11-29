  [![Test](https://github.com/mccraigmccraig/freyja/actions/workflows/test.yml/badge.svg)](https://github.com/mccraigmccraig/freyja/actions/workflows/test.yml)
[![Hex.pm](https://img.shields.io/hexpm/v/freyja.svg)](https://hex.pm/packages/freyja)
[![Documentation](https://img.shields.io/badge/documentation-gray)](https://hexdocs.pm/freyja/)

# Freyja

## Installation

Add `freyja` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:freyja, "~> 0.1.1"}
  ]
end
```

---

## What is Freyja?

Freyja is an Algebraic Effects system for Elixir, enabling you to write programs as pure functions that describe all their side effects as "effect" data structures. These effects are then interpreted by handlers, providing a clean separation between **what** your program does (the effects) and **how** it does it (the handlers).

## 0. tl;dr

Algebraic Effects and Handlers for Elixir. Both first-order and higher-order
effects are supported. A `with`-like syntax is introduced to help with
sequencing computations:

``` elixir
defhefty process_order(order_id) do
  # First-order effects are auto-lifted in hefty (higher-order) blocks
  order <- EctoFx.query(Queries, :find_order, %{id: order_id})

  # Pattern matching with else clause for failures
  {:ok, validated} <- validate_order(order)

  # More effects - state tracking
  count <- State.get()
  _ <- State.put(count + 1)

  # Higher-order effect: transaction wrapping
  result <- EctoFx.transaction(
    hefty do
      _ <- EctoFx.update(Order.confirm_changeset(validated))
      _ <- EctoFx.insert(AuditLog.changeset(%{order_id: order_id, action: "confirmed"}))
      return({:confirmed, validated})
    end
  )

  return(result)
else
  # Handle pattern match failures (e.g., validate_order returned {:error, _})
  {:error, :invalid_items} -> return({:rejected, :invalid_items})
  {:error, reason} -> return({:rejected, reason})
catch
  # Handle thrown errors (e.g., from EctoFx operations)
  :db_connection_error -> return({:error, :database_unavailable})
  thrown -> return({:error, thrown})
end
```

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
of them - it gives access to "apparently mutable" (not really mutable!)
state cells - from anywhere inside a nested stack of pure functions, without
having to add any extra parameters to function signatures

`TaggedState` has a signature module `Freyja.Effects.TaggedState`, which
defines some structs which represent the "operations" the effect supports,
`%TaggedState.Get{tag: <tag>}` and `%TaggedState.put{tag: <tag>, val: <val>}`,
and some "constructor functions" `&TaggedState.get/1` and `&TaggedState.put/2`

```elixir
# TaggedState: get/put state associated with a tag
defmodule Freyja.Effects.TaggedState do
  alias Freyja.Freer

  # Effect structs - plain data describing operations
  defmodule GetTagged do
    defstruct [:tag]
  end

  defmodule PutTagged do
    defstruct [:tag, :val]
  end

  # Constructor functions wrap structs in Freer.Impure via send_effect
  def get(tag), do: %GetTagged{tag: tag} |> Freer.send_effect()
  def put(tag, val), do: %PutTagged{tag: tag, val: val} |> Freer.send_effect()
end
```

The constructor functions like `get(tag)` and `put(tag, val)` build effect
operation structs and wrap them in a minimal `Freer.Impure` structure using
`Freer.send_effect/1`. This `Impure` struct is what gets interpreted by
Handlers - see section 3.2 for more details on how `send_effect` and
`Impure` work.

Remember that the effect structs themselves are just simple data - they
are used to signal that a computation wants to do something, but they
neither _do_ anything nor say _how_ a thing should be done.

```elixir
%Freyja.Effects.TaggedState.GetTagged{tag: :cart}
%Freyja.Effects.TaggedState.PutTagged{tag: :cart, val: [:item_a, :item_b]}
```

Handlers decide exactly what to do with them — read from ETS, append to a log,
store in a map, or something else entirely.

### 1.2 Define Your Own Effect Language

Most applications invent their own "impure verbs". With Freyja you can codify
those verbs as effect structs instead of performing side effects immediately.

```elixir
# Domain-specific storage effect
defmodule MyApp.Storage do
  alias Freyja.Freer
  
  defmodule Query do
    defstruct [:table, :id]
  end

  defmodule Change do
    defstruct [:table, :record]
  end

  # Constructor functions use send_effect to wrap structs in Freer.Impure
  def query(table, id), do: %Query{table: table, id: id} |> Freer.send_effect()
  def change(table, record), do: %Change{table: table, record: record} |> Freer.send_effect()
end

# Domain-specific notification effect
defmodule MyApp.Notifications do
  alias Freyja.Freer
  
  defmodule SendPush do
    defstruct [:user_id, :message]
  end

  def send_push(user_id, message), do: %SendPush{user_id: user_id, message: message} |> Freer.send_effect()
end
```

Your pure business logic can now "describe" what it needs. The `con` macro
helps you compose (first-order) effectful computations using a familiar
`with`-like syntax:

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

At this point, `checkout/2` is an entirely pure function —it only has pure
domain logic and emits effect structs, while handlers will decide how to
interpret them: hitting real services, wrapping DB access in transactions,
or using mocks in tests.

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

### 2.1 EctoFx: Taming dataabase interactions

The [`ecto_user_service.ex`](https://github.com/mccraigmccraig/freyja/blob/main/lib/freyja/examples/ecto_user_service.ex)
example shows how to build domain services that use Ecto effects for queries and
mutations, while keeping domain logic completely testable without a database.

**The Problem**: Traditional Ecto code tightly couples domain logic to the database:

```elixir
def create_user_with_profile(attrs) do
  Repo.transaction(fn ->
    user = Repo.insert!(User.changeset(attrs))
    profile = Repo.insert!(Profile.changeset(user, attrs))
    {user, profile}
  end)
end
```

This is hard to test without a database. **With EctoFx effects**:

```elixir
defhefty register_user(attrs) do
  # Check if email already exists
  existing <- EctoFx.query(Queries, :find_user_by_email, %{email: attrs.email})

  result <-
    case existing do
      nil ->
        # Email not taken - create user and profile in transaction
        EctoFx.transaction(
          hefty do
            user <- EctoFx.insert(User.changeset(attrs))
            profile <- EctoFx.insert(Profile.changeset(user, attrs))
            return({user, profile})
          end
        )

      _user ->
        # Email already taken - return error via Throw
        Throw.throw_error({:email_taken, attrs.email})
    end

  return(result)
end
```

**In tests** - no database needed! Use `EctoFx.TestHandler` with stubbed queries:

```elixir
state =
  EctoFx.TestHandler.new()
  |> EctoFx.TestHandler.stub_query(Queries, :find_user_by_email, %{email: "alice@test.com"}, nil)

outcome =
  EctoUserService.register_user(%{name: "Alice", email: "alice@test.com"})
  |> EctoFx.TestHandler.run(state)
  |> Lift.Algebra.run()
  |> Throw.Handler.run()
  |> Run.run()

assert {:ok, {%User{name: "Alice"}, %Profile{}}} = outcome.result
```

**In production** - real database with `EctoFx.Handler`:

```elixir
outcome =
  EctoUserService.register_user(%{name: "Alice", email: "alice@example.com"})
  |> EctoFx.Handler.run(MyApp.Repo, %{Queries => :direct})
  |> Lift.Algebra.run()
  |> Throw.Handler.run()
  |> Run.run()
```

**Benefits**:
- Domain logic stays pure and testable
- Test handler automatically applies changeset changes, validating your logic
- Same code works with real DB or test stubs
- Transactions compose naturally with other effects


### 2.2 Coroutine-Based Programming

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

### 2.3 EffectLogger: Log, Replay, and Resume Anything

#### (a) Automatic Log Collection

By inserting `EffectLogger.Handler.run/1` at the start of the Handler
pipeline, you get full logs of every effect emitted—perfect for audit,
tracing, or offline debugging.

```elixir
outcome =
  con do
    config <- TaggedReader.ask(:config)
    starting <- State.get()
    updated = starting + config
    _ <- State.put(updated)
    return(updated)
  end
  |> EffectLogger.Handler.run(EffectLogger.Log.new())
  |> TaggedReader.Handler.run(%{config: 32})
  |> State.Handler.run(10)
  |> Run.run()

outcome.result # => 42
IO.inspect(outcome, pretty: true) # output below
```

Example output (abridged):

```elixir
%Freyja.Run.RunOutcome{
  result: 42,
  outputs: %{
    Freyja.Effects.TaggedReader.Handler => %{config: 32},
    Freyja.Effects.EffectLogger.Handler => %Freyja.Effects.EffectLogger.Log{
      stack: [],
      queue: [
        %Freyja.Effects.EffectLogger.StepLogEntry{
          effects_stack: [],
          effects_queue: [
            %Freyja.Effects.EffectLogger.EffectLogEntry{
              sig: Freyja.Effects.TaggedReader,
              data: %Freyja.Effects.TaggedReader.AskTagged{tag: :config}
            }
          ],
          completed?: true,
          value: 32
        },
        %Freyja.Effects.EffectLogger.StepLogEntry{
          effects_stack: [],
          effects_queue: [
            %Freyja.Effects.EffectLogger.EffectLogEntry{
              sig: Freyja.Effects.State,
              data: %Freyja.Effects.State.Get{}
            }
          ],
          completed?: true,
          value: 10
        },
        %Freyja.Effects.EffectLogger.StepLogEntry{
          effects_stack: [],
          effects_queue: [
            %Freyja.Effects.EffectLogger.EffectLogEntry{
              sig: Freyja.Effects.State,
              data: %Freyja.Effects.State.Put{val: 42}
            }
          ],
          completed?: true,
          value: 10
        }
      ],
      allow_divergence?: false
    },
    Freyja.Effects.State.Handler => 42
  },
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

`Run.rerun/2` will "run" a computation from "cold" logs (after a JSON
serialization/deserialization roundtrip). Until the final
step `rerun` doesn't really run anything other than the pure domain code -
it supplies logged effect `values` to each step of the computation,
so every step gets the _exact same_ data that was logged during the
failed computation run. At the final step (signalled by the
`:allow_divergence?` flag in the `Log`), where an error may
have been raised, it switches back to "new computation" mode and
handles the effect normally, allowing bugfixed code to continue normally after
the error.

you can try it out in IEx with:
[`Freyja.Examples.EffectLoggerRerun`](https://github.com/mccraigmccraig/freyja/blob/main/lib/freyja/examples/effect_logger_rerun.ex):

```elixir
buggy = Freyja.Examples.EffectLoggerRerun.build(:original)
buggy_outcome = buggy |> Freyja.Run.run()
buggy_outcome.result # => {:error, :validation_failed}
json = buggy_outcome |> Jason.encode!()

fixed = Freyja.Examples.EffectLoggerRerun.build(:patched)
fixed_outcome = Freyja.Run.rerun(fixed, Jason.decode!(json))
fixed_outcome.result # => {:ok, :ok}
```

#### (c) Cold Resume from Logs

```elixir
builder = Freyja.Examples.EffectLoggerResume.build()
outcome = builder |> Freyja.Run.run()
{:suspend, prompt, _} = outcome.result
checkpoint = Jason.encode!(outcome)

# Later
decoded_checkpoint = Jason.decode!(checkpoint)
resumed = Freyja.Run.resume(builder, decoded_checkpoint, :new_value)
resumed.result # => {:done, :new_value}
```

EffectLogger’s serialized state is also enough to "cold" resume a coroutine from
deserialized logs, even though the original continuation has been lost! See
[`Freyja.Examples.EffectLoggerResume`](https://github.com/mccraigmccraig/freyja/blob/main/lib/freyja/examples/effect_logger_resume.ex)
for a copy/pasteable builder demonstrating the pattern in IEx.

### 2.4 Change Capture with EctoFx

The [`ecto_change_capture.ex`](https://github.com/mccraigmccraig/freyja/blob/main/lib/freyja/examples/ecto_change_capture.ex)
example demonstrates capturing intended database changes without immediately
persisting them - enabling batch operations, dry-run mode, and audit logging.

**The Pattern**: Write simple per-record processing functions that use
`EctoFx.Changes` to record changes, then use `EctoFx.capture/1` to collect
them without persisting:

```elixir
# Simple per-record processing function
defhefty anonymize_user(user) do
  changeset = User.anonymize_changeset(user)

  # Record the change (captured, not persisted)
  _ <- EctoFx.Changes.update(changeset)

  # Also record an audit log entry
  audit_changeset = AuditLog.changeset(%{
    user_id: user.id,
    action: "anonymize",
    details: %{original_email: user.email}
  })
  _ <- EctoFx.Changes.insert(audit_changeset)

  return(Ecto.Changeset.apply_changes(changeset))
end

# Capture changes from processing multiple users
defhefty anonymize_users_with_capture(user_ids) do
  users <- EctoFx.query(Queries, :find_users_by_ids, %{ids: user_ids})

  # EctoFx.capture/1 collects all EctoFx.change calls without persisting
  {anonymized_users, captured_changes} <-
    EctoFx.capture(FxList.fx_map(users, &anonymize_user/1))

  return({anonymized_users, captured_changes})
end
```

The captured changes are returned as `%{inserts: [...], updates: [...], deletes: [...]}`
containing Ecto changesets. Apply them in bulk within a transaction:

```elixir
defhefty transactional_anonymize(user_ids) do
  EctoFx.transaction(
    hefty do
      users <- EctoFx.query(Queries, :find_users_by_ids, %{ids: user_ids})

      # Capture all changes without persisting
      {anonymized, changes} <-
        EctoFx.capture(FxList.fx_map(users, &anonymize_user/1))

      # Persist inserts in bulk (audit logs)
      _ <- EctoFx.insert_all(AuditLog, EctoFx.to_entries(changes.inserts))

      # Persist updates in bulk using upsert
      _ <- EctoFx.insert_all(
        User,
        EctoFx.to_entries(changes.updates),
        on_conflict: :replace_all,
        conflict_target: [:id]
      )

      return({anonymized, changes})
    end
  )
end
```

**Use Cases**:
- **Batch processing**: Process 1000 users individually, but INSERT/UPDATE in bulk
- **Dry-run mode**: Capture changes without applying them, show what would change
- **Audit logging**: Record exactly what changes were intended before applying
- **Validation**: Validate the entire batch before committing any changes
- **Testing**: Verify change logic without touching the database

### 2.5 TaggedReader: Stable Signatures When Requirements Change

The [`tagged_reader_dynamic_context.ex`](https://github.com/mccraigmccraig/freyja/blob/main/lib/freyja/examples/tagged_reader_dynamic_context.ex)
example demonstrates how algebraic effects keep function signatures stable
when requirements change.

**The Problem**: In traditional code, adding context to a deep function
requires changing every intermediate function's signature:

```elixir
# Original
def generate_report(accounts), do: Enum.map(accounts, &summarize/1)
def summarize(account), do: %{name: account.name, spending: sum(account)}

# After requirements change - need greetings context
def generate_report(accounts, greetings), do: Enum.map(accounts, &summarize(&1, greetings))
def summarize(account, greetings), do: %{..., greeting: greetings[account.country]}
```

**The Solution**: With `TaggedReader`, the deep function simply asks for what
it needs. No intermediate functions change:

```elixir
# generate_report NEVER changes - works with any summarizer
defhefty generate_report(accounts, summarizer_fn) do
  FxList.fx_map(accounts, summarizer_fn)
end

# Version 1: Simple summary
defhefty summarize_spending(account) do
  total = sum_transactions(account.recent_transactions)
  return(%{name: account.name, recent_spending: total})
end

# Version 2: Requirements change! Need greeting - just ASK for it
defhefty summarize_with_greeting(account) do
  greetings <- TaggedReader.ask(:greetings)
  total = sum_transactions(account.recent_transactions)
  greeting = Map.get(greetings, account.country, "Hello!")
  return(%{name: account.name, recent_spending: total, greeting: greeting})
end
```

The context is provided at handler configuration time, completely decoupled
from the function call chain:

```elixir
# Version 1 - no context needed
TaggedReaderDynamicContext.build_v1(accounts)
|> Run.run()

# Version 2 - greetings provided at handler level
greetings = %{"UK" => "Cheerio!", "US" => "Howdy!", "DE" => "Guten Tag!"}

TaggedReaderDynamicContext.build_v2(accounts, greetings)
|> Run.run()
# => [%{name: "Alice", recent_spending: 41.49, greeting: "Cheerio!"}, ...]
```

**Benefits**:
- **Stable signatures**: Intermediate functions don't change when deep functions need more context
- **Separation of concerns**: Business logic doesn't know where context comes from
- **Easy testing**: Provide different context maps for different test scenarios
- **Incremental extension**: Add more `TaggedReader.ask` calls as requirements evolve

---

## 3. How does it work

Let's look at a simple computation and develop an intuition for how it works:

``` elixir
con do
  x <- State.get()
  y <- Reader.ask()
  return(x + y)
end
```

This computation has a series of "steps", which correspond to lines inside the
`con` block. We can read the steps as follows:

* `get` the current `State` and bind it to variable `x`
* `ask` the `Reader` for its value, and bind it to variable `y`
* `return` `x+y` to the caller

This is the "surface" interpretation of what's happening - and it's a reasonable
approximation, but it hides considerable detail. Here's a more detailed reading:

* `State.get()` builds a simple `%Get{}` struct which is returned as the
   current `non-terminal` value of the computation to an interpreter, to ask
   the `State` effect for its value
* the interpreter identifies a `Handler` which can interpret `State` requests
   and calls it to get a value from somewhere - it could be anywhere at the
   discretion of the `Handler` - and the computation is resumed with that value
   which is bound immediately to `x` (`x` is in fact a function parameter -
   see section 3.1 for how this happens)
* `Reader.ask()` builds a simple `%Ask{}` struct which is returned as a
   `non-terminal` value to the interpreter, requesting the value from the
   `Reader` effect
* the interpreter identifies a `handler` which can interpret `Reader` requests,
   calls it to get a value, and the computation is resumed again with that value,
   which is bound to `y`
* `return` returns the `terminal` value `x+y` to the interpreter, which seeing
   a terminal value returns to its caller with that value

The `con` block makes the "surface" interpretation easy, and that's
deliberate - it's an abstraction built to give a convenient mental building
block, but sometimes it's a good idea to understand the details, so in the
next couple of sections we'll look at how the computation is broken down into
steps, and those steps are exposed to an interpreter

### 3.1 The `con` and `hefty` Macros: Breaking down binds

The `con` and `hefty` macros provide a `with`-like syntax that rewrites to nested
`bind` calls. This is similar to Haskell's `do` notation.

#### Simple Rewrite Rules

The macros apply a simple transformation:

1. **Effect binding** (`x <- effect()`) becomes a `bind` call
2. **Pure binding** (`x = value`) stays as a regular assignment
3. **The last expression** is returned as-is (it must be a `Freer.t()` for
   `con`, or a `Hefty.t()` for `hefty` - so plain values should be
   wrapped with `return(value)`)
4. **Functions** with `con` or `hefty` bodies can be defined with `defcon`
   `defhefty`

#### Example: `con` macro expansion

```elixir
# Input: con block with effect bindings
con do
  x <- State.get()
  y <- Reader.ask()
  return(x + y)
end

# Expands to: nested bind calls
State.get()
|> Freyja.Freer.bind(fn x ->
  Reader.ask()
  |> Freyja.Freer.bind(fn y ->
    return(x + y)
  end)
end)
```

#### Example: `defcon` macro expansion

The `defcon` macro defines a function with a `con` body. Pure `=` assignments
are preserved inline within the continuation:

```elixir
# Input
defcon double_state() do
  x <- State.get()
  doubled = x * 2
  _ <- State.put(doubled)
  return(doubled)
end

# Expands to
def double_state() do
  import Freyja.Freer.BaseOps

  State.get()
  |> Freyja.Freer.bind(fn x ->
    doubled = x * 2
    State.put(doubled)
    |> Freyja.Freer.bind(fn _ ->
      return(doubled)
    end)
  end)
end
```

#### Example: `hefty` macro expansion

The `hefty` macro works the same way but uses `Hefty.bind` instead:

```elixir
# Input
defhefty anonymize_users_with_capture(user_ids) do
  users <- EctoFx.query(Queries, :find_users_by_ids, %{ids: user_ids})
  {results, changes} <- EctoFx.capture(FxList.fx_map(users, &anonymize_user/1))
  return({results, changes})
end

# Expands to
def anonymize_users_with_capture(user_ids) do
  import Freyja.Hefty, only: [return: 1]

  EctoFx.query(Queries, :find_users_by_ids, %{ids: user_ids})
  |> Freyja.Hefty.bind(fn users ->
    EctoFx.capture(FxList.fx_map(users, &anonymize_user/1))
    |> Freyja.Hefty.bind(fn {results, changes} ->
      return({results, changes})
    end)
  end)
end
```

#### Key Points

- The right-hand side of `<-` must return an effect computation (`Freer.t()` for `con`, `Hefty.t()` for `hefty`)
- First-order effects (State, Reader, etc.) are auto-lifted in `hefty` blocks via the `IHeftySendable` protocol
- The `return(value)` function wraps a value in a pure computation (`Freer.pure` or `Hefty.pure`)
- Unlike `with`, bindings happen inside the `do` block, not before it - this is
  due to limitations in the syntax expressible with Elixir macros
  (vs special forms like `with`)

### 3.2 Freer - let's interpret some effects in IEx

Now we have a rough idea of how the computations in `con` and `hefty` blocks
can be understood, and how they are expanded into normal Elixir code,
let's develop that intuition further by manually performing the role of
the interpreter and the `Handlers` the interpreter calls to deal with
individual effects

We'll focus on first-order effects - they are effects which
_do not_ contain other effects in their data-structure, and are simpler
to deal with - the `con` macro is used to expand first-order effects,
while the `hefty` macro is used to expand higher-order effects.

Freyja uses a type called `Freer` to capture steps in a computation. `Freer`
has two structs: There's `Pure` which wraps an ordinary-value, and
represents a `terminal` state of a computation, and `Impure` which
represents `non-terminal` states of a computation and holds:
  * `sig` - an identifier for the type of the `data` - an "effect" module
  * `data` - a piece of data which can be interpreted (by a `Handler`) to
     yield an ordinary-value - this is an "operation" of an "effect"
  * `q` - a queue of continuations `(ordinary_value -> Freer.t())` being
     the remaining steps in the computation

```elixir
defmodule Freer do

  defmodule Pure do
    defstruct val: nil

    @type t :: %__MODULE__{
            val: any
          }
  end

  defmodule Impure do
    defstruct sig: nil, data: nil, q: []

    @type t :: %__MODULE__{
            sig: atom,
            data: any,
            # should be list((any->freer))
            q: list((any -> freer))
          }
  end

  @type t() :: %Pure{} | %Impure{}
end
```

There are a few functions you will need to know about:
* `Freer.return(any) :: Freer.t()` - a.k.a `Freer.pure` - wraps an ordinary
  value in a `%Freer.Pure{}` struct - this is how ordinary values from pure
  computations get "lifted" into something the interpreter can deal with,
  and how computations signal "we're done with this step" to the interpreter
* `Freer.send_effect(any) :: Freer.t()` - this wraps an effect operation
  struct (it can be any type, but structs are nicer so the convention is
  to use them) into a minimal `%Freer.Impure{}` struct, with just
  `&Freer.pure/1` in its continuation queue. Remember `Freer.Impure` is
  a non-terminal state of the computation, so it's saying to the interpreter
  "here's something you are going to need to interpret, by finding a
  Handler for"
* `bind(Freer.t(), (any -> Freer.t())) :: Freer.t()` - `bind` is how
  computations move forward from one step to the next. It takes a `Freer`
  computation, extracts a value from it (the job of the interpreter) and
  gives that value to a "continuation" - which returns another `Freer` -
  a modified computation, now including the additional function of the
  next "step"

Let's look again at the expansion of the simple `con` block from above, and
by manually playing the role of the interpreter and `Handlers` see how
the computation gets represented as `Freer` and how the non-terminal
`Impure` structs get repeatedly interpreted until there is only
a terminal `Pure` struct.

``` elixir
con do
  x <- State.get()
  y <- Reader.ask()
  return(x + y)
end
```
and its expansion:

``` elixir
State.get()
|> Freyja.Freer.bind(fn x ->
  Reader.ask()
  |> Freyja.Freer.bind(fn y ->
    return(x + y)
  end)
end)
```

At the start we have `State.get()`, which is an "effect constructor" call -
it uses `Freer.send_effect` to wrap a simple effect data structure in a minimal
`Impure` structure - try it out yourself in IEx:

``` elixir
Freyja.Effects.State.get()

# %Freyja.Freer.Impure{
#  sig: Freyja.Effects.State,
#  data: %Freyja.Effects.State.Get{},
#  q: [&Freyja.Freer.pure/1]
#}
```
looking at the expansion again, we can see that the output of `State.get()` is
immediately fed to a `Freer.bind`

here's the whole expansion without aliases, for copy/paste into IEx:

``` elixir
freer_1 = (
  Freyja.Effects.State.get()
  |> Freyja.Freer.bind(fn x ->
    Freyja.Effects.Reader.ask()
    |> Freyja.Freer.bind(fn y ->
      Freyja.Freer.return(x + y) end) end)
)

#%Freyja.Freer.Impure{
#  sig: Freyja.Effects.State,
#  data: %Freyja.Effects.State.Get{},
#  q: [&Freyja.Freer.pure/1, #Function<42.113135111/1 in :erl_eval.expr/6>]
#}
```

now you can see what the `Freer.bind` call has done - it's cheating, and hasn't
done any work at all! It's just added the continuation function from its second
argument to the end of the `Impure`'s continuation `q` - but it has done
nothing to interpret the `%State.Get{}` effect struct in the `data` field.

This is the heart of how Algebraic Effects work in Freyja - pure steps in domain
calculations are expressed as a queue of continuations in `Freer.Impure` structs.
Those pure steps perform no side-effects, and when they want a side-effect
they return an effect operation struct to an `Impure`, along with a continuation
which resumes the computation once the effect operation has been performed
by the interpreter.

The `data` effect operation struct in the `Impure` describes some impure action
that the program wants to do, without specifying anything about _how_ the impure
action is to be achieved - that is left entirely up to the interpreter and its
`Handlers`. Let's continue playing the interpreter, and
say that our `State.Get` operation is going to retrieve the value `5` from some
state somewhere - so we pass that value to the first continuation in
the `q` (which is `&Freer.pure/1`) which, as expected, just gives us the
value `5` wrapped in a `Freer.Pure` struct.

``` elixir
freer_2 = (List.first(freer_1.q)).(5)
# %Freyja.Freer.Pure{val: 5}
```

Since `Pure` just wraps an ordinary-value, it needs no further
interpretation, and we can pop the first continuation from the `q`,
and pass the value we have - `5` - straight on to the next
continuation from the `q`:

``` elixir
freer_3 = (Enum.at(freer_1.q, 1)).(5)

#%Freyja.Freer.Impure{
#  sig: Freyja.Effects.Reader,
#  data: %Freyja.Effects.Reader.Ask{},
#  q: [&Freyja.Freer.pure/1, #Function<42.113135111/1 in :erl_eval.expr/6>]
#}
```

Now we've got something different! We have a new effect to interpret, an `Ask`
this time, and more continuations in the `q` to pass results to... This `Ask`
struct was built by the `Freyja.Effects.Reader.ask()` call in the
computation, inside the continuation passed to the first `bind` call.

Let's skip over the `Freer.pure` call we now have at the head of the
queue, because we know what it's going to do (just wrap the value in `Pure`),
and let's say interpreting the `Ask` returns a value of `15`, because we're
both the interpreter and the `Handler` and we can do that:

``` elixir
freer_4 = (Enum.at(freer_3.q, 1)).(15)
# %Freyja.Freer.Pure{val: 20}
```

And we have arrived - we called the final continuation, the function taking
parameter `y` in the expansion corresponding to the last line of
the `con` block, and it added together our two interpreted values and `return`ed
the result - and since `return` represents a terminal state and we have no more
continuations on the `q`, the value is returned to the caller

This process we have followed is essentially what the Freyja interpreter does -
it pattern-matches on the `sig` and `data` in `Impure` structs, finds a `Handler`
to interpret the effect (producing an ordinary value), then passes that value
to the next continuation in the queue. The `Freyja.Run.impl` module
orchestrates this loop.

---

# WIP below

---

### 3.2 Freer
* the Freer structs
* composing Freer operations
* bind & return
* the con / defcon sugar macros
  * they are _simple_ rewrites - RHS must always be Freer.t() or ISendable
  * why they can't have an exactly parallel syntax to with (binds before do/end)
* def_effect_struct
  * ISendable
* handlers - EffectHandler behaviour

### 3.3 Hefty
* why higher-order effects are different
* the Hefty structs
* composing Hefty operations
* bind & return
* the hefty /defhefty sugar macros
  * RHS must always be Hefty.t(), Freer.t(), ISendable, or IHeftySendable
* interoperability with Freer computations
* catch clauses
* def_hefty_struct
  * IHeftySendable
* Hefty Algebras - elaboration via interpose
    * how higher-order effects maintain their context alongside control effects liike suspend

---

## 4. Available effects

### 4.1 first-order effects
* Reader  / TaggedReader
* Writer / TaggedWriter
* State / TaggedSTate
* Throw
* Coroutine
* EffectLogger
### 4.2 higher-order effects
* Catch
* Bracket
* FxList
* Lift

---

## 5. Building your own effects

* signature module
* operation structs
* handler module/s
* algebra modules/s


## References

- **Hefty Algebras Paper**: [Poulsen & van der Rest (POPL 2023)](https://dl.acm.org/doi/10.1145/3571255)
- **Heftia (Haskell)**: [sayo-hs/heftia](https://github.com/sayo-hs/heftia)
- **Algebraic Effects Overview**: [What is algebraic about algebraic effects?](https://arxiv.org/abs/1807.05923)
- **Freer Monads, More Extensible Effects**: [Kiselyov & Ishii](https://okmij.org/ftp/Haskell/extensible/more.pdf)
- **freer-simple — a friendly effect system for Haskell**: [lexi-lambda/freer-simple](https://github.com/lexi-lambda/freer-simple)
- **effects - an Elixir effect system**: [bootstarted/effects](https://github.com/bootstarted/effects)
- **freer - an Elixir Freer monad**: [aemaeth-me/freer](https://github.com/aemaeth-me/freer)
---

## License

[MIT License](LICENSE)
