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

_Recommended reading:_ [“What is Algebraic about Algebraic Effects?”](https://interjectedfuture.com/what-is-algebraic-about-algebraic-effects/)
offers a gentle introduction to the theory and motivation behind this style.

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

> **Note:** When your application “language” is a set of documented effect
> structs, you can expose that language to tooling (including LLMs) almost for
> free. Register the effect constructors with a simple MCP server, document them
> like any other API, and the model can issue those effect commands directly.
> There’s no extra glue code—your existing pure functions already express the
> available operations.

---

## 2. A Quick Tour: Cool Things Algebraic Effects Enable

### 2.1 Coroutine-Based Programming (with Hot or Cold Resume)

Coroutine effects let you suspend and resume computations. Your domain logic can be
completely agnostic about how responses are gathered—interactive UI, CLI prompts,
or batch pipelines can all drive the same pure core.

```elixir
computation =
  con do
    amount <- Coroutine.yield("how much?")
    return("final amount: #{amount}")
  end

builder = computation |> Freyja.Effects.Coroutine.Handler.run()

outcome = builder |> Run.run()
# outcome.result => {:suspend, "how much?", continuation}

# Hot resume (same process, immediate continuation)
outcome2 = Run.resume(builder, outcome, 42)
# outcome2.result => {:done, "final amount: 42"}

# Cold resume (later, from JSON) — see Section 2.2(c) for details
json = outcome |> Jason.encode!()
decoded = Jason.decode!(json)
outcome3 = Run.resume(builder, decoded, 99)
# outcome3.result => {:done, "final amount: 99"}
```

### 2.2 EffectLogger: Log, Replay, and Resume Anything

```elixir
outcome =
  con do
    old_state <- State.put(10)
    return(old_state)
  end
  |> Freyja.Effects.EffectLogger.Handler.run(Freyja.Effects.EffectLogger.Log.new())
  |> State.Handler.run(5)
  |> Run.run()

IO.inspect(outcome, pretty: true)
```

Example output (abridged):

```elixir
%RunOutcome{
  result: 5,
  outputs: %{
    Freyja.Effects.EffectLogger.Handler => %EffectLogger.Log{
      stack: [],
      queue: [
        %StepLogEntry{
          effects_stack: [
            %EffectLogEntry{sig: Freyja.Effects.State, data: %State.Put{val: 10}}
          ],
          effects_queue: [],
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

`Run.rerun/2` automatically enables “allow divergence” so you can step past the
original error and verify your fix without reproducing the entire scenario.

#### (c) Cold Resume from Logs

```elixir
{:suspend, prompt, _} = outcome.result
checkpoint = Jason.encode!(outcome)

# Later
decoded_checkpoint = Jason.decode!(checkpoint)
resumed = Run.resume(builder, decoded_checkpoint, :new_value)
```

EffectLogger’s serialized state is enough to resume a coroutine or re-run a
failed computation on another machine.

### 2.3 TaggedWriter: Capture Structured Logs

TaggedWriter accumulates log entries under arbitrary tags, and you can call it
from deep helper functions without threading any extra arguments:

```elixir
defmodule Audit do
  def log(action), do: TaggedWriter.tell(:audit, action)
end

defmodule Database do
  def run_query(q) do
    con do
      _ <- TaggedWriter.tell(:db, {:query, q})
      # ... run the query ...
      return(:ok)
    end
  end
end

result =
  con [TaggedWriter] do
    _ <- Audit.log(:started)
    _ <- Database.run_query("SELECT 1")
    _ <- TaggedWriter.tell(:audit, :finished)
    return(:ok)
  end
  |> TaggedWriter.Handler.run(%{})
  |> Run.run()

# result.outputs[TaggedWriter.Handler]
# => %{audit: [:finished, :started], db: [{:query, "SELECT 1"}]}
```

Handlers can interpret tag streams however they like: persist them, route them to
structured logging infrastructure, or expose subsets to tools.

### 2.4 Commands as Effects (Great for MCP/LLM Tooling)

Because effects are just documented structs, you can easily build a
“command processor” that loops forever by yielding for the next command
Any tool (UI, CLI, MCP, LLM) can send "commands" with _any_ of your
application language effects by simply resuming with effect structs.

```elixir
defmodule MyApp.Commands.Stop do
  defstruct []
end

defmodule MyApp.CommandProcessor do
  def loop do
    con do
      next_command <- Coroutine.yield(:next_command)

      case next_command do
        %MyApp.Storage.Query{} ->
          _ <- MyApp.Storage.query(next_command.table, next_command.id)
          loop()

        %MyApp.Notifications.SendPush{} ->
          _ <- MyApp.Notifications.send_push(next_command.user_id, next_command.message)
          loop()

        %MyApp.Commands.Stop{} ->
          return(:stopped)

        other ->
          Throw.throw_error({:unknown_command, other})
      end
    end
  end
end

# Run the processor and feed commands
builder =
  MyApp.CommandProcessor.loop()
  |> MyApp.Storage.PostgreSQLHandler.run(db_conn)
  |> MyApp.Notifications.PigeonHandler.run(push_adapter)
  |> Throw.Handler.run()
  |> Coroutine.Handler.run()

processor = Run.run(builder)

# Send commands
processor = Run.resume(builder, processor, %MyApp.Storage.Query{table: :products, id: "SKU-123"})
processor = Run.resume(builder, processor, %MyApp.Notifications.SendPush{user_id: 5, message: "Hi!"})
final = Run.resume(builder, processor, %MyApp.Commands.Stop{})
```

Because commands are just structs, you can expose or restrict them however you
like—register them with MCP, log them, or feed them from a script/LLM—all without
extra glue code.
```

You can whitelist which effects are exposed, log them, or mock their handlers—
no extra integration layer required.
