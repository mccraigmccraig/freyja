defmodule Freyja.Examples.CommandProcessor do
  @moduledoc """
  Example of a coroutine-based command processor that loops forever, yielding for
  the next command. Commands are modeled as plain effect structs so they can be
  issued by UIs, CLIs, or MCP/LLM tooling.
  """

  import Freyja.Freer.FreerBlock

  alias Freyja.Effects.Coroutine
  alias Freyja.Effects.Throw

  # Effect definitions for the domain ----------------------------------------

  defmodule Storage do
    import Freyja.Freer.Sig.DefEffectStruct

    def_effect_struct(Query, table: nil, id: nil)
    def_effect_struct(Change, table: nil, record: nil)

    def query(table, id), do: %Query{table: table, id: id}
    def change(table, record), do: %Change{table: table, record: record}
  end

  defmodule Notifications do
    import Freyja.Freer.Sig.DefEffectStruct

    def_effect_struct(SendPush, user_id: nil, message: nil)

    def send_push(user_id, message), do: %SendPush{user_id: user_id, message: message}
  end

  @doc """
  Build a runnable pipeline for the command processor so it can be executed from
  IEx (or tests) with `Run.run/1` followed by calls to `Run.resume/3`.

  Example usage:

  ```
  alias Freyja.Examples.CommandProcessor.Storage

  builder = Freyja.Examples.CommandProcessor.builder()
  processor = Freyja.Run.run(builder)
  outcome = Freyja.Run.resume(builder, processor, Storage.query(:products, "A1"))
  # => %RunOutcome{result: {:done, {:ok, :stopped}}, ...}

  # inspect the commands that were run
  outcome.outputs[Freyja.Examples.CommandProcessor.Storage.Handler]
  ```

  Running a list of commands:

  ```
  alias Freyja.Examples.CommandProcessor.Storage
  alias Freyja.Examples.CommandProcessor.Notifications

  builder = Freyja.Examples.CommandProcessor.builder()
  processor = Freyja.Run.run(builder)

  # run some commands
  commands = [
    Storage.query(:products, "A1"),
    Storage.change(:users, %{id: 1, name: "Ann"}),
    Notifications.send_push(1, "Hello!"),
    :stop
  ]
  final_outcome = Enum.reduce(commands, processor, fn cmd, outcome ->
    Freyja.Run.resume(builder, outcome, cmd)
  end)
  # => %RunOutcome{result: {:done, {:ok, :stopped}}, ...}

  # now inspect the commands that were run
  final_outcome.outputs[Freyja.Examples.CommandProcessor.Storage.Handler]
  final_outcome.outputs[Freyja.Examples.CommandProcessor.Notifications.Handler]
  ```
  """
  def builder do
    loop()
    |> Storage.Handler.run()
    |> Notifications.Handler.run()
    |> Throw.Handler.run()
    |> Coroutine.Handler.run()
  end

  # Handlers that record operations for testing/demo -------------------------

  defmodule Storage.Handler do
    @behaviour Freyja.Freer.EffectHandler

    alias Freyja.Freer.Impure
    alias Freyja.Freer.Impl
    alias Freyja.Examples.CommandProcessor.Storage

    def handles?(%Impure{sig: Storage}, _state), do: true
    def handles?(_, _), do: false

    def interpret(
          %Impure{data: %Storage.Query{} = query, q: q},
          _key,
          state,
          _run_state
        ) do
      new_state = %{state | queries: [query | state.queries]}
      {Impl.q_apply(q, {:ok, query}), new_state}
    end

    def interpret(
          %Impure{data: %Storage.Change{} = change, q: q},
          _key,
          state,
          _run_state
        ) do
      new_state = %{state | changes: [change | state.changes]}
      {Impl.q_apply(q, {:ok, change}), new_state}
    end

    def initialize(_comp, _key, nil, _run_state), do: %{queries: [], changes: []}

    def run(builder), do: Freyja.Run.RunBuilder.add(builder, __MODULE__)
  end

  defmodule Notifications.Handler do
    @behaviour Freyja.Freer.EffectHandler

    alias Freyja.Freer.Impure
    alias Freyja.Freer.Impl
    alias Freyja.Examples.CommandProcessor.Notifications

    def handles?(%Impure{sig: Notifications}, _state), do: true
    def handles?(_, _), do: false

    def interpret(
          %Impure{data: %Notifications.SendPush{} = push, q: q},
          _key,
          state,
          _run_state
        ) do
      new_state = %{state | pushes: [push | state.pushes]}
      {Impl.q_apply(q, {:ok, push}), new_state}
    end

    def initialize(_comp, _key, nil, _run_state), do: %{pushes: []}

    def run(builder), do: Freyja.Run.RunBuilder.add(builder, __MODULE__)
  end

  # Coroutine loop ------------------------------------------------------------

  defcon loop, [Coroutine, Throw] do
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
end
