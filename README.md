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
one of them - it gives access to "apparently mutable" (not really mutable!) 
state cells - from anywhere inside a nested stack of pure functions, without
having to add any extra parameters to function signatures

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

### 2.1 Query: Decouple Domain Logic from Storage Plumbing

The [`query_example.ex`](https://github.com/mccraigmccraig/freyja/blob/main/lib/freyja/examples/query_example.ex)
shows how a single effect can express “run this query” without knowing which
backend will satisfy it. Domain code asks for data by specifying a logical
`domain`, a module/function pair, and a params struct; handlers decide whether to
hit Postgres, Elastic, or a canned test response.

```elixir
defmodule Domain do
  import Freyja.Freer.FreerBlock
  alias Freyja.Effects.Query

  defcon fetch_profile(user_id) do
    user <- Query.request(:users, Backend, :fetch_user, %{id: user_id})
    orders <- Query.request(:orders, Backend, :fetch_orders, %{user_id: user_id})
    stats <- Query.request(:stats, Backend, :fetch_stats, %{user_id: user_id})
    return(%{user: user, orders: orders, stats: stats})
  end
end
```

Because `Query.request/4` returns a plain Freer effect, the same domain code can
run against a live registry:

```elixir
Domain.fetch_profile(42)
|> Query.Handler.run(%{
  users: :direct,
  orders: :direct,
  stats: &QueryExample.route_stats/4
})
|> Run.run()
```

…or a canned response map in tests:

```elixir
responses = %{
  Query.key(:users, Backend, :fetch_user, %{id: 42}) => %{id: 42, name: "Test User"},
  Query.key(:orders, Backend, :fetch_orders, %{user_id: 42}) => []
}

Domain.fetch_profile(42)
|> Query.TestHandler.run(responses)
|> Run.run()
```

This keeps domain logic free of storage plumbing while still letting handlers
control authentication, connection pools, and mocking concerns.


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

### 2.4 Change Capture with TaggedWriter

From the IEx runnable [`change_capture.ex`](https://github.com/mccraigmccraig/freyja/blob/main/lib/freyja/examples/change_capture.ex)
example here is a trimmed down snippet showing how an application domain
`ApplyAllChanges` effect can internally use `TaggedWriter`, and `State` effects
to capture changes emitted in nested funcion calls.

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
```

``` elixir
defhefty process_users(ids, process_user_fn) do
  users <- Storage.query(ids)
  {updated_users, logs} <- Storage.apply_all_changes(FxList.fx_map(users, process_user_fn))
  count <- State.get()
  return(%{updated_users: updated_users, all_logs: logs, processed_count: count})
end
```

Each `process_user_fn` processing function (e.g., `remove_email_from_user/1`)
can use different effects, such as`Storage.change/2`, `TaggedWriter.tell/2`,
or throw errors without requiring any changes to the `process_users/2`
function signature (such as adding accumulator parameters).


---

# WIP below

---

## 3. How does it work

### 3.1 The building blocks - Freer, Hefty,, con, hefty
### 3.1 Freer
* the Freer structs
* composing Freer operations
* bind & return
* the con / defcon sugar macros
  * they are _simple_ rewrites - RHS must always be Freer.t() or ISendable
  * why they can't have an exactly parallel syntax to with (binds before do/end)
* def_effect_struct
  * ISendable
* handlers - EffectHandler behaviour

### 3.2 Hefty
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
