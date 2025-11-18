defmodule Freyja.Run do
  @moduledoc """
  Functions to manage a priority-list of EffectHandlers and run a computation
  in the context of that list of EffectHandlers

  EffectHandlers are structs implementing the EffectHandler behaviour
  """
  alias Freyja.Freer
  alias Freyja.Freer.Impl
  alias Freyja.Freer.Impure
  alias Freyja.OkResult
  alias Freyja.Freer.Pure
  alias Freyja.Protocols.Result
  alias Freyja.Freer.Sig.ISendable
  alias Freyja.Run.RunEffects
  alias Freyja.Run.RunEffects.ScopedOk
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
          result: %Freyja.SuspendResult{continuation: k},
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

  @spec run(Freer.freer(), RunState.t()) :: RunOutcome.t()
  def run(computation, %RunState{} = run_state)
      when is_struct(computation, Pure) or is_struct(computation, Impure) do
    initialized_run_state = initialize(computation, run_state)

    do_run(computation, initialized_run_state)
  end

  def run(computation, %RunState{} = run_state) do
    ISendable.send(computation) |> run(run_state)
  end

  @doc """
  Interpret effects and finalize outputs - the main client-facing
  computation runner
  """
  @spec do_run(Freer.freer(), RunState.t()) :: RunOutcome.t()
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
         %Pure{val: val} = computation,
         %RunState{
           handlers: handlers
         } = run_state
       ) do
    # if we get to the finalize phase and no effect has decided upon
    # what type of output it's going to be, then it's an OkResult,
    # signalling a normal completion
    computation = if !Result.type(val), do: %Pure{val: %OkResult{value: val}}, else: computation

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

  # use the EffectHandler.scoped_ok function to update each of the
  # effect states after a scoped handler returns
  #
  # returns: an updated Map of effect states
  @spec scoped_ok_effect_states(RunState.t(), ScopedOk.t()) :: map
  defp scoped_ok_effect_states(
         %RunState{handlers: handlers, states: effect_states},
         %ScopedOk{
           value: value,
           run_outcome:
             %RunOutcome{
               result: scoped_effect_result,
               run_state: %RunState{states: scoped_effect_states}
             } = scoped_run_outcome
         }
       ) do
    handlers
    |> Enum.reduce(effect_states, fn {key, mod}, effect_states ->
      if function_exported?(mod, :scoped_ok, 6) do
        updated_effect_state =
          mod.scoped_ok(
            scoped_effect_result,
            value,
            key,
            Map.get(effect_states, key),
            Map.get(scoped_effect_states, key),
            scoped_run_outcome
          )

        Map.put(effect_states, key, updated_effect_state)
      else
        # default - accept the scoped state
        Map.put(effect_states, key, Map.get(scoped_effect_states, key))
      end
    end)
  end

  # use the EffectHandler.scoped_error function to update each of the
  # effect states after a scoped handler returns
  #

  @doc """
  Interpret effects until there is only %Pure{} remaining - does not finalize.
  Useful for Effect handlers which want to run a sub-computation and control
  the outputs (e.g. discard or commit to the parent)
  """
  @spec interpret(Freer.freer(), RunState.t()) :: {Pure.t(), RunState.t()}
  def interpret(
        %Pure{val: val} = computation,
        %RunState{} = run_state
      ) do
    # if we get to the finalize phase and no effect has decided upon
    # what type of output it's going to be, then it's an OkResult,
    # signalling a normal completion
    computation = if !Result.type(val), do: %Pure{val: %OkResult{value: val}}, else: computation

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

  # blessed handler for ScopedOks - it must be handled here, because
  # the EffectHandler behaviour does not support effects which can
  # change other effect's state - instead, the optional
  # EffectHandler.scoped_return funciton is offered, which allows
  # handlers to override their own scoped_return action, and this
  # blessed interpreter can call that function for every EffectHandler
  # (which implements it)
  def interpret_one(
        %Impure{
          sig: RunEffects,
          data:
            %ScopedOk{
              value: val,
              run_outcome: %RunOutcome{result: _scoped_result}
            } = scoped_return,
          q: q
        } = _computation,
        %RunState{} = run_state
      ) do
    # Logger.error(
    #   "#{__MODULE__} ScopedOk\n" <>
    #     "effect: #{inspect(computation, pretty: true)}" <>
    #     "run_state: #{inspect(run_state, pretty: true)}\n"
    # )

    updated_effect_states = scoped_ok_effect_states(run_state, scoped_return)

    interpreted = {
      Impl.q_apply(q, val),
      %{run_state | states: updated_effect_states}
    }

    # Logger.error(
    #   "#{__MODULE__} ScopedOk OUT\n" <>
    #     "effect: #{inspect(elem(interpreted, 0), pretty: true)}" <>
    #     "run_state: #{inspect(elem(interpreted, 1), pretty: true)}\n"
    # )

    interpreted
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
