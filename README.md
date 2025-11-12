# Freyja

**Algebraic Effects for Elixir**

---

## What is Freyja?

Freyja brings algebraic effects and handlers to Elixir, enabling you to write programs as pure functions that return effect data structures whenever they need to perform side effects. These effect structures are then interpreted by handlers, providing a clean separation between **what** your program does (the effects) and **how** it does it (the handlers).

This separation enables powerful capabilities: the same program can be tested with mock handlers, run with different implementations in different environments, have all operations logged for audit trails, and even be replayed for debugging - all without changing the program code itself.

Beyond clean architecture, Freyja's effect-based approach makes your application naturally ready for modern use cases like LLM agent integration via MCP (Model Context Protocol), where effects serve as serializable, composable tool interfaces. See [`MCP_EFFECTS_2.md`](MCP_EFFECTS_2.md) for details.

---

## Quick Example

Here's a real-world example showing effect composition with change tracking:

```elixir
import Freyja.Con
alias Freyja.Effects.{State, FxList, TaggedWriter}

# Define effect operations as pure data structures
defmodule Storage do
  import Freyja.Sig.DefEffectStruct

  def_effect_struct(Query, ids: [])
  def_effect_struct(UpdateAll, changes: [])
  def_effect_struct(ApplyAllChanges, computation: nil)

  def query(ids), do: %Query{ids: ids}
  def update_all(changes), do: %UpdateAll{changes: changes}
  def apply_all_changes(computation), do: %ApplyAllChanges{computation: computation}
end

# Write effectful programs using con blocks
defcon process_users(user_ids) do
  # Query users from storage
  users <- Storage.query(user_ids)

  # Process each user, capturing changes
  {updated_users, all_logs} <-
    users
    |> FxList.fx_map(&remove_email/1)
    |> Storage.apply_all_changes()

  # Get count from state effect
  count <- State.get()

  return(%{
    updated: updated_users,
    changes: all_logs[:changes],
    count: count
  })
end

defcon remove_email(user) do
  updated = Map.delete(user, :email)

  # Record the change using Storage effect
  Storage.change(user, updated)

  # Increment counter using State effect
  State.update(&(&1 + 1))

  return(updated)
end
```

The effects (`Storage.query`, `Storage.change`, `State.update`) are pure data structures. Handlers interpret them at runtime, which means you can:
- Test with mock handlers (no database needed)
- Log all operations for audit trails
- Replay operations for debugging
- Swap handlers for different environments

Full example: [`lib/freyja/examples/change_capture.ex`](https://github.com/mccraigmccraig/freyja/blob/main/lib/freyja/examples/change_capture.ex)

---

## Key Benefits

### Testability

Swap handlers to test programs without real side effects:

```elixir
# Production: Real database
run(program, [Storage.PostgresHandler], %{})

# Test: Mock data
run(program, [Storage.MockHandler], %{mock_data: fixtures})
```

### Composability

Handlers can compose effects to implement higher-level operations:

```elixir
# Lower-level effect: record a change
def interpret(%Storage.Change{old: old, new: new}, _, state, %{q: q}) do
  # Record change by writing to TaggedWriter
  tell_comp = TaggedWriter.tell(:changes, {old, new})
  {Impl.bindp(tell_comp, q), state}
end

# Higher-level effect: capture and apply all changes
def interpret(%ApplyAllChanges{computation: comp}, _, state, %{q: q}) do
  composed =
    con do
      # Run computation and capture all changes written via Storage.change
      {result, logs} <- TaggedWriter.listen(comp)
      changes = logs[:changes] || []

      # Apply captured changes in bulk
      Storage.update_all(changes)

      return({result, logs})
    end

  {Impl.bindp(composed, q), state}
end
```

The `Storage.change` handler writes to TaggedWriter, and `ApplyAllChanges` uses `TaggedWriter.listen` to capture all changes made during the computation, then applies them in bulk. Programs use these effects without knowing the implementation details.

### Auditability

Effect operations are data structures that can be logged:

```elixir
# Log every effect operation
EffectLogger.log(computation)

# Replay later for debugging
EffectLogger.replay(logged_effects)
```

Complete audit trail with deterministic replay.

### Multiple Interfaces

Define effects once, expose through multiple interfaces:
- **Elixir API**: Direct function calls
- **MCP**: LLM agent tools (see [`MCP_EFFECTS_2.md`](MCP_EFFECTS_2.md))
- **HTTP**: REST endpoints
- **CLI**: Command-line tools
- **Tests**: Mock implementations

### Clean Architecture

Effect/handler separation enforces:
- Pure business logic (programs that create effects)
- Isolated side effects (handlers that interpret effects)
- Clear boundaries between layers
- Easy to reason about control flow

---

## Installation

If [available in Hex](https://hex.pm/docs/publish), the package can be installed
by adding `freyja` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:freyja, "~> 0.1.0"}
  ]
end
```

Documentation can be generated with [ExDoc](https://github.com/elixir-lang/ex_doc)
and published on [HexDocs](https://hexdocs.pm). Once published, the docs can
be found at <https://hexdocs.pm/freyja>.

---

## Available Effects

Freyja provides several built-in effects for common patterns:

### State Management

- **`State`** - Single mutable state cell
  ```elixir
  con do
    current <- State.get()
    State.put(current + 1)
    return(current + 1)
  end
  ```

- **`TaggedState`** - Multiple independent state values indexed by tags
  ```elixir
  con do
    count <- TaggedState.get(:counter)
    TaggedState.put(:counter, count + 1)
    return(count + 1)
  end
  ```

### Environment/Context

- **`Reader`** - Read-only environment value
  ```elixir
  con do
    config <- Reader.ask()
    return(config.database_url)
  end
  ```

- **`TaggedReader`** - Multiple independent environment values
  ```elixir
  con do
    db <- TaggedReader.ask(:database)
    cache <- TaggedReader.ask(:cache)
    return({db, cache})
  end
  ```

### Logging/Output

- **`Writer`** - Accumulate output values
  ```elixir
  con do
    Writer.tell("Starting process")
    result <- do_work()
    Writer.tell("Process complete")
    return(result)
  end
  ```

- **`TaggedWriter`** - Multiple independent output streams indexed by tags
  ```elixir
  con do
    TaggedWriter.tell(:audit, %{action: :user_created})
    TaggedWriter.tell(:metrics, %{event: :signup})
    return(:ok)
  end
  ```

### Control Flow

- **`Error`** - Exception-style error handling
  ```elixir
  con do
    result <- Error.catch_fx(
      con do
        user <- get_user(id)
        return(user)
      end
    )

    case result do
      {:ok, user} -> return(user)
      {:error, err} -> return(:not_found)
    end
  end
  ```

- **`Coroutine`** - Suspend and resume computations
  ```elixir
  defcon process_items(items) do
    result <- fx_map(items, fn item ->
      con do
        processed <- process(item)
        Coroutine.yield(processed)  # Yield intermediate result
        return(processed)
      end
    end)
    return(result)
  end
  ```

### Composition

- **`FxList`** - Effectful operations over collections
  ```elixir
  con do
    # Map with effects
    results <- fx_map([1, 2, 3], fn x ->
      con do
        State.update(&(&1 + 1))
        return(x * 2)
      end
    end)

    # Reduce with effects
    sum <- fx_reduce([1, 2, 3], 0, fn x, acc ->
      con do
        Writer.tell("Processing #{x}")
        return(acc + x)
      end
    end)

    return({results, sum})
  end
  ```

### Observability

- **`EffectLogger`** - Log and replay effect operations
  ```elixir
  # Log all effects during execution
  {result, log} = EffectLogger.run_with_log(computation, handlers)

  # Replay logged effects
  replayed_result = EffectLogger.replay(log, handlers)
  ```

---

## Examples and Learning More

### Examples

- **Change Capture Pattern**: [`lib/freyja/examples/change_capture.ex`](https://github.com/mccraigmccraig/freyja/blob/main/lib/freyja/examples/change_capture.ex)
  - Demonstrates composing State, Writer, and FxList effects
  - Shows handler composition with `con` blocks
  - Real-world pattern for batch updates with change tracking

### Documentation

- **MCP Integration**: [`MCP_EFFECTS_2.md`](MCP_EFFECTS_2.md)
  - How algebraic effects naturally fit MCP tool interfaces
  - Exposing your application to LLM agents
  - Complete TodoApp example with handler composition

- **Future: Hefty Algebras**: [`HEFTY.md`](HEFTY.md)
  - Planned support for higher-order effects
  - Modular elaboration of complex effect patterns
  - Based on POPL 2023 research

### Testing

See test files for usage patterns:
- [`test/freyja/effects/fx_list_test.exs`](https://github.com/mccraigmccraig/freyja/blob/main/test/freyja/effects/fx_list_test.exs) - FxList patterns
- [`test/freyja/effects/state_test.exs`](https://github.com/mccraigmccraig/freyja/blob/main/test/freyja/effects/state_test.exs) - State management
- [`test/freyja/effects/error_test.exs`](https://github.com/mccraigmccraig/freyja/blob/main/test/freyja/effects/error_test.exs) - Error handling patterns

---

## Contributing

Contributions are welcome! Please feel free to open issues or submit pull requests.

## License

[Your license here]
