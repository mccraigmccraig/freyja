# Algebraic Effects as MCP Tool Interfaces

## 1. The Core Insight

Algebraic effects in Freyja are pure, serializable data structures that describe computational intent without prescribing implementation. This structural property creates a natural alignment with MCP (Model Context Protocol) tool interfaces.

The observation: application capabilities expressed as effect operations are already in the form needed for LLM tool interfaces - they're serializable data, self-documenting, type-safe, composable, and interpretable through handlers.

This means that applications built with algebraic effects can expose their functionality to LLM agents with minimal translation overhead, while maintaining the same architectural benefits that make effects valuable for traditional software engineering: testability, modularity, and clean separation of concerns.

---

## 2. What Makes an Effective MCP Tool Interface

For LLM agents to effectively use application capabilities through MCP, tool interfaces should provide:

### 2.1 Serializable Representations

Tools must be invoked with data that can cross process boundaries - typically JSON. This requires:
- Parameters representable as primitive types, arrays, and objects
- Results that can be encoded without loss of meaning
- No reliance on language-specific constructs (closures, processes, etc.)

### 2.2 Clear Interface/Implementation Separation

The tool signature (what it does) should be independent of implementation (how it does it):
- LLM understands the interface without knowing implementation details
- Implementation can change without breaking LLM's understanding
- Same interface can have different implementations in different contexts

### 2.3 Composability

Complex operations should be buildable from simpler primitives:
- Basic operations can combine into workflows
- Higher-level operations can be defined in terms of lower-level ones
- Composition mechanism should be clear and predictable

### 2.4 Type Safety and Validation

Prevent invalid invocations before execution:
- Parameter types specified in schemas
- Validation happens at construction time
- Type errors surface early rather than during execution

### 2.5 Auditability and Replay

For safety and debugging:
- Record what operations were performed
- Reconstruct execution history from logs
- Replay operations for debugging or testing

### 2.6 Safety and Access Control

Control what operations are permitted:
- Whitelist safe operations
- Restrict dangerous operations
- Different permission levels for different contexts
- Sandboxing for untrusted execution

---

## 3. Algebraic Effects Fundamentals

### 3.1 Effects as Pure Data Structures

An algebraic effect operation is a data structure describing an action to be performed:

```elixir
defmodule Storage do
  import Freyja.Freer.Sig.DefEffectStruct

  def_effect_struct(Query, ids: [])
  def_effect_struct(UpdateAll, changes: [])
end

# Operations are plain structs:
%Storage.Query{ids: [1, 2, 3]}
%Storage.UpdateAll{changes: [{old, new}]}
```

The structure describes **what** to do, not **how** to do it.

### 3.2 The Freer Monad Foundation

In Freyja, effectful computations are represented using a Freer monad:

```elixir
defmodule Freyja.Freer do
  defmodule Pure do
    defstruct [:val]  # Terminal value
  end

  defmodule Impure do
    defstruct [:sig, :data, :q]
    # sig: Effect signature (identifies the effect)
    # data: The operation struct
    # q: Continuation queue
  end
end
```

Programs are built by sequencing operations with `bind`. The `con` macro 
provides some sugar over `bind`, and a familiar with-like syntax:

```elixir
con do
  users <- Storage.query([1, 2, 3])
  updated <- Storage.update_all(changes)
  return(updated)
end
```

This creates a computation tree that can be interpreted by handlers.

### 3.3 Handlers: From Interface to Implementation

Handlers provide the semantics for effect operations:

```elixir
defmodule Storage.Handler do
  @behaviour Freyja.EffectHandler

  def handles?(%Impure{sig: sig}, _), do: sig == Storage

  def interpret(%Storage.Query{ids: ids}, _, state, _) do
    # Actual implementation
    result = Repo.all(from u in User, where: u.id in ^ids)
    {Freer.pure(result), state}
  end
end
```

The same effect operation can have different handlers:
- Development: In-memory mock data
- Production: Database queries
- Testing: Fixtures
- LLM context: Limited, sandboxed operations

### 3.4 Composition Through Handler Orchestration

Handlers can compose multiple effects to implement higher-level operations. From [`change_capture.ex`](https://github.com/mccraigmccraig/freyja/blob/main/lib/freyja/examples/change_capture.ex):

```elixir
def interpret(%ApplyAllChanges{computation: computation}, _, state, %{q: q}) do
  # Handler composes multiple effects using con block
  composed =
    con do
      # 1. Run computation and capture logs
      {result, all_logs} <- TaggedWriter.listen(computation)

      # 2. Extract changes from logs
      changes = all_logs[:changes] || []

      # 3. Apply changes in bulk
      Storage.update_all(changes)

      # 4. Return result
      return({result, all_logs})
    end

  {Impl.bindp(composed, q), state}
end
```

This pattern allows building complex operations from simpler ones within handler implementations.

---

## 4. The Natural Alignment: Why Effects Fit MCP

### 4.1 Serialization: No Translation Needed

**Criterion**: Tool parameters and results must be serializable.

**Algebraic effects**: Already pure data structures.

```elixir
# Effect struct
%Storage.Query{ids: [1, 2, 3]}

# Serializes trivially to JSON
{
  "effect": "Storage.Query",
  "params": {"ids": [1, 2, 3]}
}
```

No translation layer, no impedance mismatch - effects are already in serializable form.

### 4.2 Interface/Implementation Separation: Built-In Abstraction

**Criterion**: LLM should understand interface without knowing implementation.

**Algebraic effects**: Effect = interface, Handler = implementation.

```elixir
# Interface (what the LLM sees)
%Storage.Query{ids: [1, 2, 3]}

# Implementation options (LLM doesn't see):
# - PostgresHandler: SELECT * FROM users...
# - MockHandler: Map.take(mock_data, ids)
# - CachedHandler: Check cache, fallback to DB
# - RateLimitedHandler: Check limits, then query
```

The effect structure remains constant while interpretations vary.

### 4.3 Composability: Handlers Orchestrate Effects

**Criterion**: Complex operations from simpler primitives.

**Algebraic effects**: Handlers compose effects via `con` blocks.

Example from previous section shows `ApplyAllChanges` composing `listen` and `update_all`. The composition happens in the handler, invisible to the LLM:

```elixir
# LLM calls high-level operation
%Storage.ApplyAllChanges{computation: ...}

# Handler orchestrates:
# - TaggedWriter.listen(...)
# - Storage.update_all(...)
# LLM doesn't need to know the orchestration
```

### 4.4 Type Safety: Struct Validation

**Criterion**: Invalid invocations caught early.

**Algebraic effects**: Structs enforce structure.

```elixir
# This succeeds
%Storage.Query{ids: [1, 2, 3]}

# This fails at construction
%Storage.Query{ids: "not a list"}  # Type error

# MCP bridge can validate before running
def execute_tool(tool_name, params, context) do
  with {:ok, effect} <- construct_effect(tool_name, params),
       {:ok, outcome} <- run_effect(effect, context) do
    {:ok, serialize(outcome)}
  end
end
```

### 4.5 Auditability: Effect Logging

**Criterion**: Record what operations were performed.

**Algebraic effects**: Freyja already has `EffectLogger`.

```elixir
# Log every effect
EffectLogger.log(computation)
# Stores: [%Query{...}, %UpdateAll{...}, ...]

# Replay later
EffectLogger.replay(logged_effects)
# Deterministic re-execution
```

Because effects are pure data, the log is complete - no hidden side effects.

### 4.6 Safety: Handler-Based Access Control

**Criterion**: Control what operations are permitted.

**Algebraic effects**: Different handlers = different capabilities.

```elixir
# Production handler - full access
defmodule Storage.ProductionHandler do
  def interpret(%Query{ids: ids}, _, state, _) do
    result = Repo.all(from u in User, where: u.id in ^ids)
    {Freer.pure(result), state}
  end
end

# LLM handler - restricted
defmodule Storage.LLMHandler do
  def interpret(%Query{ids: ids}, _, state, _) do
    if length(ids) > 100 do
      {Freer.pure({:error, :too_many_ids}), state}
    else
      result = Repo.all(from u in User, where: u.id in ^ids, limit: 100)
      {Freer.pure(result), state}
    end
  end
end
```

Same effect, controlled interpretation based on context.

### 4.7 Comparison with Traditional Approaches

**vs. REST APIs**:
- REST: HTTP-specific, string routing, manual docs, hard to compose
- Effects: Protocol-agnostic, type-safe, auto-docs, natural composition

**vs. GraphQL**:
- GraphQL: Query language required, schema separate from types
- Effects: Direct structures, schema derived from code

**vs. Function Calling (OpenAI style)**:
- Function calling: Schema separate, no composition, no audit trail
- Effects: Schema from structs, composable, logged by default

---

## 5. Implementation Patterns with Freyja

### 5.1 Basic Effect Definition

Effects are defined using the `def_effect_struct` macro:

```elixir
defmodule TodoApp.Effects do
  import Freyja.Freer.Sig.DefEffectStruct

  @doc "List all todos, optionally filtered"
  def_effect_struct(ListTodos, filters: %{})

  @doc "Get a single todo by ID"
  def_effect_struct(GetTodo, id: nil)

  @doc "Create a new todo"
  def_effect_struct(CreateTodo, title: nil, description: nil, assignee_id: nil)

  @doc "Update a todo"
  def_effect_struct(UpdateTodo, id: nil, changes: %{})

  @doc "Delete a todo"
  def_effect_struct(DeleteTodo, id: nil)

  # Helper functions
  def list_todos(filters \\ %{}), do: %ListTodos{filters: filters}
  def get_todo(id), do: %GetTodo{id: id}
  def create_todo(title, desc, assignee_id \\ nil),
    do: %CreateTodo{title: title, description: desc, assignee_id: assignee_id}
  def update_todo(id, changes), do: %UpdateTodo{id: id, changes: changes}
  def delete_todo(id), do: %DeleteTodo{id: id}
end
```

Each `def_effect_struct` creates a struct type that represents an operation.

### 5.2 Basic Handler Implementation

Handlers interpret effects by pattern matching:

```elixir
defmodule TodoApp.Handler do
  @behaviour Freyja.EffectHandler

  alias Freyja.Freer
  alias Freyja.Freer.{Impl, Impure}
  alias TodoApp.Effects

  def handles?(%Impure{sig: sig}, _), do: sig == TodoApp.Effects

  def interpret(%Effects.ListTodos{filters: filters}, _, state, _) do
    query = from t in Todo

    query = if filters[:status] do
      from t in query, where: t.status == ^filters[:status]
    else
      query
    end

    query = if filters[:completed_before] do
      from t in query, where: t.completed_at < ^filters[:completed_before]
    else
      query
    end

    todos = Repo.all(query)
    {Freer.pure(todos), state}
  end

  def interpret(%Effects.GetTodo{id: id}, _, state, %{q: q}) do
    case Repo.get(Todo, id) do
      nil ->
        # Throw error if not found - error handling via effects
        error_comp = Freyja.Effects.Error.throw_fx({:not_found, :todo, id})
        {Impl.bindp(error_comp, q), state}

      todo ->
        {Freer.pure(todo), state}
    end
  end

  def interpret(%Effects.CreateTodo{title: title, description: desc, assignee_id: assignee}, _, state, _) do
    todo = %Todo{
      title: title,
      description: desc,
      assignee_id: assignee,
      status: :pending,
      created_at: DateTime.utc_now()
    } |> Repo.insert!()

    {Freer.pure(todo), state}
  end

  def interpret(%Effects.DeleteTodo{id: id}, _, state, _) do
    {count, _} = Repo.delete_all(from t in Todo, where: t.id == ^id)
    {Freer.pure(count), state}
  end
end
```

### 5.3 Handler Composition with Con Blocks

Handlers can implement higher-level effects by composing lower-level ones:

```elixir
defmodule TodoApp.Effects do
  # ... basic effects from above ...

  # Higher-level composed effects
  @doc """
  Create a todo and track analytics.
  Composes CreateTodo + Analytics tracking.
  """
  def_effect_struct(CreateAndTrack, title: nil, description: nil, user_id: nil)

  @doc """
  Complete a todo and notify assignees.
  Composes GetTodo + UpdateTodo + Notification.
  """
  def_effect_struct(CompleteAndNotify, id: nil)

  @doc """
  Archive completed todos older than a date.
  Composes ListTodos + bulk delete + Analytics.
  """
  def_effect_struct(ArchiveCompleted, before_date: nil)
end
```

Handler implementation using `con` blocks to sequence effects:

```elixir
defmodule TodoApp.Handler do
  import Freyja.Con
  alias Freyja.Effects.FxList

  # Analytics helper effects
  defmodule Analytics do
    import Freyja.Freer.Sig.DefEffectStruct
    def_effect_struct(TrackEvent, event: nil, properties: %{})
    def_effect_struct(RecordMetric, metric: nil, value: 0)
  end

  defmodule Notifications do
    import Freyja.Freer.Sig.DefEffectStruct
    def_effect_struct(NotifyUsers, user_ids: [], message: nil)
  end

  # ... basic handlers from above ...

  # Higher-level handler using composition
  def interpret(%Effects.CreateAndTrack{title: title, description: desc, user_id: user_id}, _, state, %{q: q}) do
    composed =
      con do
        # 1. Create the todo
        todo <- Effects.create_todo(title, desc, nil)

        # 2. Track creation event
        Analytics.track_event("todo_created", %{
          todo_id: todo.id,
          user_id: user_id,
          timestamp: DateTime.utc_now()
        })

        # 3. Record metric
        Analytics.record_metric("todos_created", 1)

        # 4. Return created todo
        return(todo)
      end

    {Impl.bindp(composed, q), state}
  end

  def interpret(%Effects.CompleteAndNotify{id: id}, _, state, %{q: q}) do
    composed =
      con do
        # 1. Get todo (throws if not found)
        todo <- Effects.get_todo(id)

        # 2. Mark as completed
        updated <- Effects.update_todo(id, %{
          status: :completed,
          completed_at: DateTime.utc_now()
        })

        # 3. Notify assignees if present
        if todo.assignee_id do
          Notifications.notify_users(
            [todo.assignee_id],
            "Todo '#{todo.title}' has been completed"
          )
        else
          return(:no_assignees)
        end

        # 4. Track completion
        Analytics.track_event("todo_completed", %{
          todo_id: id,
          completion_time_seconds: DateTime.diff(updated.completed_at, todo.created_at, :second),
          had_assignee: todo.assignee_id != nil
        })

        # 5. Return updated todo
        return(updated)
      end

    {Impl.bindp(composed, q), state}
  end

  def interpret(%Effects.ArchiveCompleted{before_date: before_date}, _, state, %{q: q}) do
    composed =
      con do
        # 1. Query completed todos before date
        to_archive <- Effects.list_todos(%{
          status: :completed,
          completed_before: before_date
        })

        # 2. Delete each using fx_reduce
        deleted_count <- FxList.fx_reduce(
          to_archive,
          0,
          fn todo, acc ->
            con do
              Effects.delete_todo(todo.id)
              return(acc + 1)
            end
          end
        )

        # 3. Track archival
        Analytics.track_event("todos_archived", %{
          count: deleted_count,
          before_date: Date.to_string(before_date),
          timestamp: DateTime.utc_now()
        })

        # 4. Return summary
        return(%{
          archived_count: deleted_count,
          archived_ids: Enum.map(to_archive, & &1.id)
        })
      end

    {Impl.bindp(composed, q), state}
  end
end
```

**Pattern**: Higher-level effects use `con` blocks to sequence lower-level effects. The LLM calls a single high-level operation; the handler orchestrates the implementation.

### 5.4 MCP Bridge: Auto-Generate Tool Definitions

Effect modules can be introspected to generate MCP tool schemas:

```elixir
defmodule Freyja.MCP.Bridge do
  @doc """
  Generate MCP tool definitions from effect module.
  """
  def effect_module_to_mcp_tools(effect_module) do
    effect_module
    |> extract_effect_structs()
    |> Enum.map(&effect_struct_to_mcp_tool/1)
  end

  defp effect_struct_to_mcp_tool(effect_struct_module) do
    %{
      name: mcp_tool_name(effect_struct_module),
      description: extract_moduledoc(effect_struct_module),
      inputSchema: struct_to_json_schema(effect_struct_module)
    }
  end

  defp struct_to_json_schema(struct_module) do
    fields = struct_module.__struct__()
    |> Map.keys()
    |> List.delete(:__struct__)

    %{
      type: "object",
      properties: fields_to_json_properties(fields, struct_module),
      required: required_fields(fields)
    }
  end
end
```

### 5.5 Tool Execution: From MCP Call to Effect

Execute MCP tool invocations by constructing and running effects:

```elixir
defmodule Freyja.MCP.Executor do
  @doc """
  Handle an MCP tool invocation.

  Steps:
  1. Map tool name to effect struct
  2. Construct effect from parameters
  3. Build Freer computation
  4. Run with configured handlers
  5. Serialize result
  """
  def execute_tool(tool_name, params, context) do
    with {:ok, effect_struct} <- construct_effect(tool_name, params),
         {:ok, computation} <- build_computation(effect_struct),
         {:ok, outcome} <- run_with_handlers(computation, context) do
      {:ok, serialize_outcome(outcome)}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp construct_effect(tool_name, params) do
    # Map "todo_create" -> TodoApp.Effects.CreateTodo
    effect_module = tool_name_to_module(tool_name)
    struct = struct(effect_module, params)
    {:ok, struct}
  rescue
    e -> {:error, {:construction_failed, e}}
  end

  defp build_computation(effect_struct) do
    computation = Freer.send_effect(
      effect_struct,
      effect_struct.__struct__ |> module_to_sig()
    )
    {:ok, computation}
  end

  defp run_with_handlers(computation, context) do
    run_state = Run.RunState.new(
      context.handlers,
      context.initial_states
    )
    outcome = Run.run(computation, run_state)
    {:ok, outcome}
  rescue
    e -> {:error, {:execution_failed, e}}
  end
end
```

**Flow**:
```
LLM JSON → construct_effect → Freer computation → run with handlers → result JSON
```

### 5.6 Security Patterns

#### Effect Whitelisting

```elixir
defmodule Freyja.MCP.Security do
  @llm_allowed_effects [
    TodoApp.Effects.ListTodos,
    TodoApp.Effects.GetTodo,
    TodoApp.Effects.CreateTodo
  ]

  @llm_forbidden_effects [
    TodoApp.Effects.DeleteTodo,     # Destructive
    System.Execute                   # Dangerous
  ]

  def check_allowed_for_llm(effect_struct) do
    module = effect_struct.__struct__

    cond do
      module in @llm_allowed_effects -> :ok
      module in @llm_forbidden_effects -> {:error, :forbidden}
      true -> {:error, :not_whitelisted}
    end
  end
end
```

#### Sandboxed Handlers

```elixir
defmodule TodoApp.LLMHandler do
  @behaviour Freyja.EffectHandler

  def interpret(%Effects.CreateTodo{}, _, state, _) do
    # Require approval for mutations
    {Freer.pure({:error, :requires_approval}), state}
  end

  def interpret(%Effects.GetTodo{id: id}, _, state, _) do
    # Read-only operations allowed
    todo = Repo.get(Todo, id)
    {Freer.pure(todo), state}
  end
end
```

### 5.7 Complete Example: TodoApp MCP Server

Putting it all together:

```elixir
defmodule TodoApp.MCP do
  def start_link do
    # 1. Generate MCP tool definitions
    tools = Freyja.MCP.Bridge.effect_module_to_mcp_tools(TodoApp.Effects)

    # 2. Start MCP server
    MCP.Server.start_link(
      name: "TodoApp",
      tools: tools,
      handler: &handle_tool_call/3
    )
  end

  defp handle_tool_call(tool_name, params, context) do
    # Execute with appropriate handlers
    Freyja.MCP.Executor.execute_tool(
      tool_name,
      params,
      %{
        handlers: [TodoApp.Handler],
        initial_states: %{}
      }
    )
  end
end
```

**LLM interaction**:

```json
{
  "call_tool": "create_and_track",
  "arguments": {
    "title": "Review PR #123",
    "description": "Review and merge PR",
    "user_id": "alice"
  }
}
```

**What happens**:
1. MCP call arrives with tool name and params
2. `construct_effect` creates `%CreateAndTrack{...}`
3. Freer computation built
4. Handler's `con` block sequences: Create + Analytics
5. Result serialized and returned to LLM

The LLM calls one high-level operation; the handler composes the implementation from lower-level effects.

---

## 6. Evaluation: Strengths, Limitations, and Applicability

### 6.1 Where This Approach Excels

#### Already Using Effect-Based Architecture

If your application is built with algebraic effects, MCP exposure becomes straightforward:
- Effects are already defined
- Handlers already implement logic
- Just add the bridge layer: `Freyja.MCP.register(MyEffects)`

#### Audit and Replay Requirements

Applications needing strong auditability:
- Financial systems
- Healthcare systems
- Compliance-heavy domains

Effect logging provides complete operation history by default.

#### Multiple Interface Types

When you need to expose functionality via:
- MCP (LLM agents)
- HTTP (REST API)
- WebSocket (real-time)
- CLI (command-line)
- Tests (mocks)

Same effects serve all interfaces - define once, expose everywhere.

#### Composition-Heavy Workflows

When operations naturally compose:
- Data processing pipelines
- Multi-step business processes
- Workflow orchestration

Handler composition with `con` blocks provides this naturally.

### 6.2 Known Limitations and Challenges

#### 1. Complexity for Simple Cases

Effect-based architecture adds indirection:

```elixir
# Direct (simpler for trivial cases)
def get_user(id), do: Repo.get(User, id)

# Effect-based (more layers)
def_effect_struct(GetUser, id: nil)
def interpret(%GetUser{id: id}, _, state, _) do
  {Freer.pure(Repo.get(User, id)), state}
end
```

For simple CRUD, the overhead may not be justified.

#### 2. Function Parameters: Direct Serialization Challenge

Functions cannot be directly serialized through MCP:

```elixir
# Works in Elixir:
fx_map(users, fn user -> transform(user) end)

# Cannot directly serialize the function via MCP:
{
  "tool": "fx_map",
  "arguments": {
    "list": [...],
    "function": "???"  # How to serialize?
  }
}
```

**Mitigation**: Provide higher-level effects that encapsulate the function application:

```elixir
# Instead of exposing fx_map directly, provide specific operations:
def_effect_struct(ArchiveCompleted, before_date: nil)

# Handler manages the function internally:
def interpret(%ArchiveCompleted{before_date: date}, _, state, %{q: q}) do
  composed =
    con do
      todos <- list_todos(%{completed_before: date})
      # fx_reduce with delete function managed by handler
      count <- FxList.fx_reduce(todos, 0, fn todo, acc ->
        con do
          delete_todo(todo.id)
          return(acc + 1)
        end
      end)
      return(count)
    end
  {Impl.bindp(composed, q), state}
end
```

The LLM calls `ArchiveCompleted` without needing to provide a function - the handler manages the delete operation.

#### 3. Type Information Boundaries

Elixir's dynamic typing means limited compile-time guarantees:

```elixir
def_effect_struct(Query, ids: [])
# No compile-time validation that ids are integers
```

JSON Schema provides runtime validation but can't express all type constraints. Complex type relationships require runtime checks.

#### 4. Learning Curve

Effect-oriented programming differs from traditional approaches:
- Separation of effect operations from handlers
- Understanding when to create new effects vs extend existing
- Effect composition patterns
- Handler state management

Teams unfamiliar with effects face adoption overhead.

#### 5. Debugging Complexity

Effect-based control flow can be less obvious:
- Stack traces span effect interpretation layers
- Need to understand handler implementation to trace execution
- Deep effect composition creates deep call stacks
- Continuation queue mechanics can be subtle

#### 6. Performance Overhead

Algebraic effects introduce runtime costs:
- Effect structure allocation
- Handler dispatching and pattern matching
- Continuation queue management
- More indirection than direct calls

For performance-critical paths, this overhead may be significant.

#### 7. Serialization Edge Cases

Some effect parameters resist serialization:

```elixir
# Process-specific values
def_effect_struct(Monitor, pid: nil)
# PIDs don't serialize across processes

# Large data
def_effect_struct(ProcessDataset, dataset: nil)
# Inefficient to serialize gigabytes

# Temporal resources
def_effect_struct(ReadFile, file_handle: nil)
# File handles don't survive serialization
```

Effects exposed via MCP must use serializable parameters only.

#### 8. Handler State Management

Stateful handlers create challenges:
- State must persist across MCP calls (sessions)
- Concurrent LLM calls may conflict on shared state
- State serialization for distributed systems
- Cleanup when sessions end

#### 9. Effect Granularity Decisions

Finding the right abstraction level is non-trivial:

```elixir
# Too granular - explosion of effect types
def_effect_struct(UpdateUserEmail, user_id: nil, email: nil)
def_effect_struct(UpdateUserName, user_id: nil, name: nil)

# Too coarse - less guidance for LLM
def_effect_struct(UpdateUser, user_id: nil, changes: %{})
```

Requires iteration and experience to find appropriate granularity.

#### 10. Ecosystem Maturity

Current state:
- Algebraic effects less common in Elixir than OTP patterns
- Fewer examples and established patterns
- Libraries may not integrate naturally with effect-based code
- Tooling (debuggers, profilers) may not understand effect semantics

### 6.3 When Alternatives May Be Preferable

#### Simple CRUD-Dominated Applications

If the application is primarily straightforward database operations:
- Effect indirection may add complexity without benefit
- Traditional Phoenix controllers may be simpler
- REST or GraphQL may be more conventional choices

#### Performance-Critical Paths

For latency-sensitive or high-throughput scenarios:
- Effect overhead may be unacceptable
- Direct implementation may be necessary
- Benchmark before committing to effects

#### Teams Unfamiliar with Effects

If the team lacks experience with algebraic effects:
- Learning curve may slow development
- Traditional approaches may be more productive initially
- Consider simpler abstractions first

#### Function-Heavy Interfaces

When operations naturally take many function parameters:
- Serialization challenges multiply
- Workarounds become complex
- May be better suited to direct SDK approach

### 6.4 Evaluation Criteria for Adoption

Before implementing MCP via algebraic effects, validate:

1. **Do your effects serialize cleanly?** Check that parameters are primitives, arrays, objects
2. **Is composition important?** If operations are mostly independent, composition benefits are limited
3. **Do you need audit/replay?** If not required, effect logging overhead may not be worth it
4. **Can you scope effects appropriately?** Test whether you can find right granularity
5. **Is performance acceptable?** Benchmark effect overhead for your workload
6. **Can you handle stateful operations?** Ensure session management is feasible
7. **Is the team ready?** Assess whether effect-oriented programming fits team capabilities

---

## 7. Implementation Roadmap

### Phase 1: Core MCP Bridge (1-2 weeks)

**Goal**: Basic effect → MCP tool mapping

**Modules**:
- `Freyja.MCP.Bridge` - Register effects, generate tool definitions
- `Freyja.MCP.Schema` - Struct to JSON Schema conversion
- `Freyja.MCP.Executor` - Construct and run effects from MCP calls

**Deliverable**: Can expose effect modules as MCP tools and execute them.

### Phase 2: Security & Audit (1 week)

**Goal**: Safe LLM interaction

**Modules**:
- `Freyja.MCP.Security` - Whitelisting, rate limiting, approval requirements
- `Freyja.MCP.Audit` - Operation logging, session history, replay

**Deliverable**: LLM operations are logged, restricted, and auditable.

### Phase 3: Workflow Composition (1-2 weeks)

**Goal**: Multi-step effect sequences

**Modules**:
- `Freyja.MCP.Workflow` - Execute sequences, validation, optimization
- `Freyja.MCP.Context` - Result binding, reference resolution

**Deliverable**: LLMs can compose multi-step workflows.

### Phase 4: Documentation & Discovery (1 week)

**Goal**: LLMs can discover available operations

**Modules**:
- `Freyja.MCP.Documentation` - Tool catalogs, usage guides
- `Freyja.MCP.Discovery` - List tools, search, get details

**Deliverable**: LLMs can explore and understand available operations.

### Phase 5: Advanced Features (2-3 weeks)

**Goal**: Production-ready capabilities

**Features**:
- Approval workflows for sensitive operations
- Effect templates for common patterns
- Monitoring and alerting
- Usage analytics

---

## 8. Validation Approach

### Prototype Phase (1-2 days)

Build minimal proof-of-concept:
1. Simple effect module (Todo example)
2. Basic handler implementation
3. MCP bridge (effect → JSON schema)
4. Tool executor (JSON → effect → result)
5. Test with actual MCP client

### Test Criteria

Evaluate prototype against:
1. **Can LLM use tools effectively?** Does the abstraction work in practice?
2. **Does serialization work cleanly?** Any edge cases in your domain?
3. **Is developer experience acceptable?** How much overhead to define effects?
4. **What are the gaps?** What's missing or problematic?

### Decision Point

Based on prototype findings:
- **If successful**: Proceed with full implementation (Phases 1-5)
- **If issues found**: Iterate on design or consider alternatives
- **If fundamental blockers**: Document findings and reconsider approach

---

## Summary

Algebraic effects provide a natural foundation for MCP tool interfaces because:

1. **Pure data structures** - Effects serialize without translation
2. **Interface/implementation separation** - Clean abstraction for LLMs
3. **Handler composition** - Complex operations from simple building blocks
4. **Self-documenting** - Schemas generated from struct definitions
5. **Auditable and replayable** - Effect logging provides these by default

The approach works best when applications are already effect-based, composition is important, and audit/replay are requirements. Known limitations include function parameter serialization (mitigated by appropriate higher-level effects), performance overhead, and ecosystem maturity.

The recommendation is to validate through prototyping before committing to full implementation, using the evaluation criteria in section 6.4 to assess fit for your specific use case.
