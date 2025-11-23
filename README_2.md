# Freyja

> _Incremental draft_ — this README is being developed section by section.
> For the stable documentation, see `README.md`.

---

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

## 2. A Quick Tour: Cool Things Algebraic Effects Enable

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

#### (a) Automatic Log Collection

By inserting `EffectLogger.Handler.run/1` at the start of the pipeline, you get
full logs of every effect emitted—perfect for audit, tracing, or
offline debugging.

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

`Run.rerun/2` will run the computatino from "cold" Logs, deserialized from
JSON, and automatically enables “allow divergence” so you can step past the
original error and verify your fix without reproducing the entire scenario.

#### (c) Cold Resume from Logs

```elixir
{:suspend, prompt, _} = outcome.result
checkpoint = Jason.encode!(outcome)

# Later
decoded_checkpoint = Jason.decode!(checkpoint)
resumed = Run.resume(builder, decoded_checkpoint, :new_value)
```

EffectLogger’s serialized state is also enough to "cold" resume a coroutine from
deserialized logs, even though the original continuation has been lost!

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
