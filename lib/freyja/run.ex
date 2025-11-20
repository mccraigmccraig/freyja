defmodule Freyja.Run do
  @moduledoc """
  Execute both Freer and Hefty computations.

  This module provides a unified interface for running both first-order (Freer)
  and higher-order (Hefty) effect computations.

  ## Freer Computations (First-Order Effects)

  For Freer computations with only first-order effects:

      Run.run(
        computation,
        [State.Handler, Writer.Handler],
        %{State.Handler => 0}
      )

  ## Hefty Computations (Higher-Order Effects)

  For Hefty computations with higher-order effects, provide algebras as the
  second parameter:

      Run.run(
        hefty_computation,
        [Catch.Algebra, Lift.Algebra],      # Elaboration phase
        [State.Handler, Error.Handler],     # Interpretation phase
        %{State.Handler => 0}
      )

  The function automatically detects whether you're running Freer or Hefty
  based on the computation structure and arity.

  ## Two-Phase Execution for Hefty

  When running Hefty computations:

  **Phase 1: Elaboration** - Transform higher-order effects into first-order effects
  **Phase 2: Interpretation** - Execute first-order effects using handlers

  Based on "Hefty Algebras: Modular Elaboration of Higher-Order Algebraic Effects"
  (Poulsen & van der Rest, POPL 2023).

  ## See Also

  - `Freyja.Hefty.Elaborate` - Elaboration catamorphism for Hefty
  - `Freyja.Hefty.Algebra` - Algebra behavior
  - Effect handlers implement `Freyja.Freer.EffectHandler` behavior
  """
  alias Freyja.Freer
  alias Freyja.Freer.Impure
  alias Freyja.Freer.Pure
  alias Freyja.Freer.Sig.ISendable
  alias Freyja.Hefty
  alias Freyja.Hefty.Elaborate
  alias Freyja.Hefty.Sig.IHeftySendable
  alias Freyja.Run.RunState
  alias Freyja.RunOutcome

  require Logger

  @type handler_mod_with_state :: {RunState.handler_key(), any}
  @type handler_spec :: RunState.handler_mod() | handler_mod_with_state()
  @type handler_spec_list :: list({RunState.handler_key(), handler_spec})

  @doc """
  Build a RunState struct with the provided EffectHandlers, and their initial state
  """
  @spec with_handlers(handler_spec_list()) :: RunState.t()
  def with_handlers(handler_specs) do
    handler_specs
    |> Enum.map(fn
      {key, mod} when is_atom(key) and is_atom(mod) -> {key, {mod, nil}}
      {key, {mod, _state}} = spec_with_state when is_atom(key) and is_atom(mod) -> spec_with_state
    end)
    |> Enum.reduce(
      %RunState{handlers: [], states: %{}},
      fn {key, {mod, state}}, acc ->
        if Map.has_key?(acc, key) do
          raise ArgumentError,
            message:
              "#{__MODULE__}.register_handler haneler_key already exists\n" <>
                "handler_key: #{inspect(key)}\n" <>
                "%run{}: #{inspect(acc, pretty: true)}"
        end

        # make sure the EffectHandler behaviours are loaded!
        Code.ensure_loaded(mod)

        %{
          acc
          | handlers: [{key, mod} | acc.handlers],
            states: Map.put(acc.states, key, state)
        }
      end
    )
    |> then(fn %RunState{handlers: handlers} = self ->
      %{self | handlers: Enum.reverse(handlers)}
    end)
  end

  @doc """
  Resume a suspended computation with a value.
  """
  def resume(
        %RunOutcome{
          result: {:suspend, _value, k},
          run_state: run_state
        },
        input
      ) do
    do_run(k.(input), run_state)
  end

  @doc """
  Rerun a computation using the outputs from a previous run as the initial states.
  This is useful for replay/resume scenarios where you want to use logged states.
  """
  def rerun(computation, %RunOutcome{outputs: outputs, run_state: previous_run_state}) do
    # Create new run state using outputs from previous run as initial states
    new_run_state = %{
      previous_run_state
      | states: outputs
    }

    do_run(computation, new_run_state)
  end

  @doc """
  Run a Freer or Hefty computation.

  This function automatically handles both first-order (Freer) and higher-order
  (Hefty) effect computations based on the arguments provided.

  ## Running Freer Computations (3 arguments)

  For Freer computations with only first-order effects:

      Run.run(
        computation,
        [State.Handler, Writer.Handler],
        %{State.Handler => 0, Writer.Handler => []}
      )

  ## Running Hefty Computations (4 arguments)

  For Hefty computations with higher-order effects, provide algebras:

      Run.run(
        hefty_computation,
        [Catch.Algebra, Lift.Algebra],      # Elaboration (algebras)
        [State.Handler, Error.Handler],     # Interpretation (handlers)
        %{State.Handler => 0}
      )

  ## Parameters

  - `computation` - The Freer or Hefty computation to run
  - `algebras_or_handlers` - For Freer: handlers list. For Hefty: algebras list
  - `handlers_or_initial_states` - For Freer: initial states. For Hefty: handlers list
  - `initial_states` - (Hefty only) Map of handler module to initial state

  ## Returns

  `RunOutcome.t()` containing:
  - `result` - Final value, {:error, reason}, or {:suspend, value, continuation}
  - `outputs` - Final handler states
  - `run_state` - RunState for resume operations
  """
  # Hefty: 4-arity with Hefty.Pure struct
  @spec run(Hefty.t(), [module], [module], map) :: RunOutcome.t()
  def run(%Hefty.Pure{} = hefty_tree, algebras, handlers, initial_states)
      when is_list(algebras) and is_list(handlers) and is_map(initial_states) do
    # Phase 1: Elaborate higher-order effects into first-order effects
    # Phase 2: Interpret first-order effects using existing infrastructure
    hefty_tree
    |> Elaborate.elaborate(algebras)
    |> run(handlers, initial_states)
  end

  # Hefty: 4-arity with Hefty.Impure struct
  def run(%Hefty.Impure{} = hefty_tree, algebras, handlers, initial_states)
      when is_list(algebras) and is_list(handlers) and is_map(initial_states) do
    hefty_tree
    |> Elaborate.elaborate(algebras)
    |> run(handlers, initial_states)
  end

  # Hefty: 4-arity with IHeftySendable protocol (auto-convert to Hefty)
  def run(hefty_tree, algebras, handlers, initial_states)
      when is_list(algebras) and is_list(handlers) and is_map(initial_states) do
    hefty_tree
    |> IHeftySendable.send_to_hefty()
    |> run(algebras, handlers, initial_states)
  end

  # Hefty: 3-arity (algebras, handlers, no initial_states) - default to %{}
  def run(hefty_tree, algebras, handlers)
      when is_list(algebras) and is_list(handlers) do
    run(hefty_tree, algebras, handlers, %{})
  end

  # Freer: 3-arity with initial_states
  @spec run(Freer.freer(), [module], map) :: RunOutcome.t()
  def run(computation, handlers, initial_states)
      when is_list(handlers) and is_map(initial_states) do
    # Build handler specs from handlers list and initial_states map
    handler_specs =
      Enum.map(handlers, fn handler_mod ->
        state = Map.get(initial_states, handler_mod)
        {handler_mod, {handler_mod, state}}
      end)

    run_state = with_handlers(handler_specs)
    run_with_state(computation, run_state)
  end

  # Freer: 2-arity (no initial_states) - default to %{}
  @spec run(Freer.freer(), [module]) :: RunOutcome.t()
  def run(computation, handlers) when is_list(handlers) do
    run(computation, handlers, %{})
  end

  @doc """
  Simplified run for Hefty computations with no handler state.

  Useful for quick prototyping or when handlers don't need initial state.

  ## Example

      computation = Catch.catch_hefty(
        Hefty.pure(42),
        fn _err -> Hefty.pure(0) end
      )

      outcome = Run.run_simple(
        computation,
        [Catch.Algebra, Lift.Algebra]
      )
  """
  @spec run_simple(Hefty.t(), [module]) :: RunOutcome.t()
  def run_simple(hefty_tree, algebras) do
    run(hefty_tree, algebras, [], %{})
  end

  # Internal: run with pre-built RunState (for Hefty.Run to call)
  @doc false
  def run_with_state(computation, %RunState{} = run_state)
      when is_struct(computation, Pure) or is_struct(computation, Impure) do
    initialized_run_state = initialize(computation, run_state)
    do_run(computation, initialized_run_state)
  end

  @doc false
  def run_with_state(computation, %RunState{} = run_state) do
    ISendable.send(computation) |> run_with_state(run_state)
  end

  @doc """
  Interpret effects and finalize outputs - the main client-facing
  computation runner
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

  # initialize output value and states - gives each Effect chance to initialize
  # its state and the result value
  @spec initialize(Freer.freer(), RunState.t()) :: RunState.t()
  defp initialize(
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

  # finalize output value and states - gives each Effect chance to finalize
  # its state and the result value
  @spec finalize(Pure.t(), RunState.t()) :: {Pure.t(), RunState.t()}
  defp finalize(
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
        # Logger.error("#{inspect(pure)}\n#{inspect(key)}\n#{inspect(run_state)}")
        {pure, updated_state} = mod.finalize(pure, key, Map.get(run_state.states, key), run_state)
        {pure, %{run_state | states: Map.put(run_state.states, key, updated_state)}}
      else
        {computation, run_state}
      end
    end)
  end

  @doc """
  Interpret effects until there is only %Pure{} remaining - does not finalize.
  Useful for Effect handlers which want to run a sub-computation and control
  the outputs (e.g. discard or commit to the parent)
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
  Interpret a single effects
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

  # is effect b different from effect a
  defp effect_equals?(b, %Impure{sig: sig, data: data, q: q} = _a) do
    case b do
      %Impure{sig: updated_sig, data: updated_data, q: updated_q} ->
        updated_sig == sig && updated_data == data && updated_q == q

      _ ->
        false
    end
  end
end
