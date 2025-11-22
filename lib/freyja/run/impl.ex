defmodule Freyja.Run.Impl do
  @moduledoc """
  Low-level interpretation engine for effect computations.

  This module contains the internal implementation of effect interpretation,
  including the main interpretation loop, handler lifecycle management, and
  effect dispatching.

  Most users should not call these functions directly - use the high-level
  API in `Freyja.Run` instead.
  """

  alias Freyja.Freer
  alias Freyja.Freer.Impure
  alias Freyja.Freer.Pure
  alias Freyja.Freer.Sig.ISendable
  alias Freyja.Run.RunState
  alias Freyja.Run.RunOutcome

  require Logger

  @doc """
  Run a computation with a pre-built RunState.

  This is the internal entry point called by the high-level Run API.
  """
  @spec run_with_state(Freer.freer(), RunState.t()) :: RunOutcome.t()
  def run_with_state(computation, %RunState{} = run_state)
      when is_struct(computation, Pure) or is_struct(computation, Impure) do
    initialized_run_state = initialize(computation, run_state)
    do_run(computation, initialized_run_state)
  end

  def run_with_state(computation, %RunState{} = run_state) do
    ISendable.send(computation) |> run_with_state(run_state)
  end

  @doc """
  Interpret effects and finalize outputs - the main computation runner.

  This is the core interpretation loop that handles Pure values, Impure effects,
  and suspensions (for Coroutine).
  """
  @spec do_run(Freer.freer(), RunState.t()) :: RunOutcome.t()
  def do_run(
        %Pure{val: %Freyja.Effects.Coroutine.Suspend{value: val, continuation: k}} = _computation,
        %RunState{} = run_state
      ) do
    # Suspensions bypass finalize - continuation captures rest of computation including finalization
    # Convert Coroutine.Suspend (private protocol) to {:suspend, _, _} tuple (public API)
    %RunOutcome{
      result: {:suspend, val, k},
      outputs: run_state.states,
      run_state: run_state
    }
  end

  def do_run(
        %Pure{} = computation,
        %RunState{} = run_state
      ) do
    # Logger.error("#{__MODULE__}.do_run finalizing!")

    # should all effects get a shot at the result ? maybe not
    {%Pure{val: final_val}, final_run_state} = finalize(computation, run_state)

    %RunOutcome{
      result: final_val,
      outputs: final_run_state.states,
      run_state: run_state
    }
  end

  def do_run(
        %Impure{} = computation,
        %RunState{} = run_state
      ) do
    {new_computation, updated_run_state} = interpret(computation, run_state)

    # Logger.error("#{__MODULE__}.after-interpret")
    # it's %Pure{} now
    do_run(new_computation, updated_run_state)
  end

  # ISendable lets us treat plain structs as Freer values
  def do_run(sendable, run_state), do: ISendable.send(sendable) |> do_run(run_state)

  @doc """
  Initialize handler states before computation starts.

  Gives each handler a chance to initialize its state and the result value.
  """
  @spec initialize(Freer.freer(), RunState.t()) :: RunState.t()
  def initialize(
        computation,
        %RunState{
          handlers: handlers
        } = run_state
      ) do
    handlers
    |> Enum.reduce(run_state, fn {key, mod}, run_state ->
      if function_exported?(mod, :initialize, 4) do
        updated_state =
          mod.initialize(computation, key, Map.get(run_state.states, key), run_state)

        %{run_state | states: Map.put(run_state.states, key, updated_state)}
      else
        run_state
      end
    end)
  end

  @doc """
  Finalize handler states after computation completes.

  Gives each handler a chance to finalize its state and the result value.
  """
  @spec finalize(Pure.t(), RunState.t()) :: {Pure.t(), RunState.t()}
  def finalize(
        %Pure{} = computation,
        %RunState{
          handlers: handlers
        } = run_state
      ) do
    # Plain values pass through unchanged - no automatic OkResult wrapping
    # Handlers return {:error, _} or other special values explicitly when needed

    handlers
    |> Enum.reduce({computation, run_state}, fn {key, mod}, {pure, run_state} ->
      if function_exported?(mod, :finalize, 4) do
        {pure, updated_state} = mod.finalize(pure, key, Map.get(run_state.states, key), run_state)
        {pure, %{run_state | states: Map.put(run_state.states, key, updated_state)}}
      else
        {pure, run_state}
      end
    end)
  end

  @doc """
  Interpret effects until there is only %Pure{} remaining - does not finalize.

  This is an internal function used by the interpretation loop.
  """
  @spec interpret(Freer.freer(), RunState.t()) :: {Pure.t(), RunState.t()}
  def interpret(
        %Pure{} = computation,
        %RunState{} = run_state
      ) do
    # Plain values pass through unchanged - no automatic OkResult wrapping
    # Handlers return {:error, _} or other special values explicitly when needed

    {computation, run_state}
  end

  def interpret(
        %Impure{} = computation,
        %RunState{} = run_state
      ) do
    {new_computation, updated_run_state} = interpret_one(computation, run_state)

    interpret(new_computation, updated_run_state)
  end

  def interpret(computation, %RunState{} = run_state),
    do: interpret(computation |> ISendable.send(), run_state)

  @doc """
  Interpret a single effect.

  Dispatches the effect to the first handler that can handle it, using the
  handler priority queue pattern.
  """
  @spec interpret_one(
          Freer.freer(),
          RunState.t()
        ) :: {Freer.freer(), RunState.t()}
  def interpret_one(
        %Pure{} = computation,
        %RunState{} = run_state
      ) do
    {computation, run_state}
  end

  def interpret_one(
        %Impure{sig: _sig, data: _u, q: _q} = effect,
        %RunState{handlers: handlers} = run_state
      ) do
    # Logger.error(
    #   "#{__MODULE__}.interpret_one\n" <>
    #     "effect: #{inspect(effect, pretty: true)}\n" <>
    #     "run_state: #{inspect(run_state, pretty: true)}"
    # )

    {new_effect, updated_run_state} =
      handlers
      |> Enum.reduce_while({effect, run_state}, fn {key, mod}, {effect, run_state} = acc ->
        # Logger.error("#{__MODULE__}.interpret reduce\n#{inspect(effect, pretty: true)}")

        handler_state = Map.get(run_state.states, key)

        if handler_type = mod.handles?(effect, handler_state) do
          reduce_action = if handler_type == :observer, do: :cont, else: :halt

          {new_effect, updated_state} = mod.interpret(effect, key, handler_state, run_state)

          {reduce_action,
           {new_effect,
            %{
              run_state
              | states: Map.put(run_state.states, key, updated_state)
            }}}
        else
          {:cont, acc}
        end
      end)

    handled? = !effect_equals?(new_effect, effect)

    if !handled? do
      # TODO replace with an error effect, for nice retry/resume
      raise ArgumentError,
        message:
          "#{__MODULE__}.run: no handler for effect in stack\n" <>
            "#{inspect(effect, pretty: true)}\n" <>
            "#{inspect(run_state, pretty: true)}"
    end

    interpreted = {new_effect, updated_run_state}

    # Logger.error(
    #   "#{__MODULE__}.interpret_one OUT\n" <>
    #     "effect: #{inspect(elem(interpreted, 0), pretty: true)}" <>
    #     "run_state: #{inspect(elem(interpreted, 1), pretty: true)}\n"
    # )

    interpreted
  end

  # Check if effect b is different from effect a
  defp effect_equals?(b, %Impure{sig: sig, data: data, q: q} = _a) do
    case b do
      %Impure{sig: updated_sig, data: updated_data, q: updated_q} ->
        updated_sig == sig && updated_data == data && updated_q == q

      _ ->
        false
    end
  end
end
