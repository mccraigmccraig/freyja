defmodule Freyja.Hefty.Effects.HeftyTaggedWriter do
  @moduledoc """
  Hefty implementation of TaggedWriter with listen as higher-order effect.

  This demonstrates migrating a scoped effect (listen) to use Hefty elaboration,
  while keeping first-order operations (tell, peek) as-is.

  ## Operations

  - `tell(tag, val)` - First-order: Write to tagged log (uses existing effect)
  - `peek(tag)` - First-order: Query tagged log (uses existing effect)
  - `listen(computation)` - Higher-order: Capture logs from computation

  ## Example

      import Freyja.HeftyMacro

      hefty do
        tell(:audit, "before listen")

        {result, logs} <- HeftyTaggedWriter.listen(hefty do
          tell(:audit, "step 1")
          tell(:debug, "debug info")
          return(42)
        end)

        # logs = %{audit: ["step 1"], debug: ["debug info"]}
        return({result, logs})
      end

  ## Migration Notes

  - tell/peek remain first-order effects (use existing TaggedWriter effect)
  - listen is new higher-order effect with Hefty elaboration
  - Uses runner effect pattern (like Catch and FxReduce)
  """

  import Freyja.Hefty.Sig.DefHeftyStruct

  # Listen operation - higher-order effect that captures logs
  def_hefty_struct(Listen, [])

  @doc """
  Execute a computation and capture all logs written during it.

  Returns `{result, captured_logs}` where captured_logs is a map of
  `%{tag => [logs]}` for all tags written to during the computation.

  ## Parameters

  - `computation` - Hefty computation to execute with log capture

  ## Example

      HeftyTaggedWriter.listen(hefty do
        tell(:audit, "event 1")
        tell(:audit, "event 2")
        return(:ok)
      end)
      # Returns: {:ok, %{audit: ["event 2", "event 1"]}}
  """
  def listen(computation) do
    Freyja.Hefty.send_hefty(
      __MODULE__,
      %Listen{},
      %{inner: computation}
    )
  end
end

# First-order runner effect for listen
defmodule Freyja.Hefty.Effects.HeftyTaggedWriter.RunListen do
  import Freyja.Freer.Sig.DefEffectStruct

  def_effect_struct(RunListen, computation: nil)

  def run_listen(computation) do
    %RunListen{computation: computation}
  end
end

defmodule Freyja.Hefty.Effects.HeftyTaggedWriter.Algebra do
  @moduledoc """
  Algebra for elaborating HeftyTaggedWriter higher-order operations.

  Currently only handles `listen` - tell and peek are first-order effects
  that use the existing TaggedWriter handler.

  ## Listen Elaboration

  The listen operation elaborates using the runner effect pattern:

  1. Create RunListen first-order effect wrapping the inner computation
  2. RunListenHandler executes it and returns `{result, captured_logs}`
  3. Elaboration just binds the result to continuation

  The handler is responsible for:
  - Capturing log changes during computation execution
  - Returning captured logs as a map
  - Propagating state changes via ScopedOk

  This is simpler than the old scoped handler approach which had complex
  log diffing logic mixed with effect interpretation.
  """

  @behaviour Freyja.Hefty.Algebra

  alias Freyja.Hefty.Effects.HeftyTaggedWriter.Listen
  import Freyja.Con
  import Freyja.Hefty.Effects.HeftyTaggedWriter.RunListen, only: [run_listen: 1]

  @impl true
  def handles?(sig) when sig == Freyja.Hefty.Effects.HeftyTaggedWriter, do: true
  def handles?(_), do: false

  @impl true
  def elaborate(%Listen{}, psi, k, _elaborator) do
    # Extract already-elaborated inner computation
    inner_comp = Map.fetch!(psi, :inner)

    # Use runner effect to execute and capture logs
    con do
      result_and_logs <- run_listen(inner_comp)
      k.(result_and_logs)
    end
  end
end

defmodule Freyja.Hefty.Effects.HeftyTaggedWriter.RunListenHandler do
  @moduledoc """
  Handler for RunListen runner effect.

  Executes a computation and captures all log writes, returning
  `{result, captured_logs_map}`.

  ## State Propagation

  Uses ScopedOk to propagate state changes from the inner computation,
  implementing non-transactional semantics (logs and other state changes
  persist regardless of errors).
  """

  @behaviour Freyja.EffectHandler

  alias Freyja.Hefty.Effects.HeftyTaggedWriter.RunListen.RunListen
  alias Freyja.Freer.Impure
  alias Freyja.Run
  alias Freyja.Run.RunState
  alias Freyja.Run.RunEffects
  alias Freyja.RunOutcome
  alias Freyja.OkResult
  alias Freyja.Effects.TaggedWriter

  @impl true
  def handles?(%Impure{sig: sig}, _state) do
    sig == Freyja.Hefty.Effects.HeftyTaggedWriter.RunListen
  end

  @impl true
  def interpret(
        %Impure{
          sig: Freyja.Hefty.Effects.HeftyTaggedWriter.RunListen,
          data: %RunListen{computation: comp},
          q: q
        },
        _handler_key,
        state,
        %RunState{} = run_state
      ) do
    # Run the inner computation
    outcome = Run.run(comp, run_state)

    # Get the initial state (before inner computation)
    initial_tw_state = Map.get(run_state.states, TaggedWriter.Handler, %{})

    # Get the final state (after inner computation)
    final_tw_state = Map.get(outcome.outputs, TaggedWriter.Handler, %{})

    # Calculate captured logs: what was added during the computation
    captured_logs = calculate_captured_logs(initial_tw_state, final_tw_state)

    # Extract the result value
    result_value =
      case outcome.result do
        %OkResult{value: val} -> val
        # Propagate errors as-is
        other -> other
      end

    # Return tuple of result and captured logs
    result_tuple = {result_value, captured_logs}

    # Use ScopedOk to propagate state changes
    # Fix RunOutcome to have updated run_state (same pattern as RunCatchingHandler)
    corrected_outcome = %RunOutcome{
      result: outcome.result,
      outputs: outcome.outputs,
      run_state: %{outcome.run_state | states: outcome.outputs}
    }

    scoped_ok_effect = %Impure{
      sig: RunEffects,
      data: %RunEffects.ScopedOk{
        value: result_tuple,
        run_outcome: corrected_outcome
      },
      q: q
    }

    {scoped_ok_effect, state}
  end

  # Calculate what logs were added during the computation
  # by comparing initial and final states
  defp calculate_captured_logs(initial_state, final_state) do
    final_state
    |> Enum.map(fn {tag, final_tag_log} ->
      initial_tag_log = Map.get(initial_state, tag, [])
      # New logs are at the front (prepended)
      new_logs = Enum.take(final_tag_log, length(final_tag_log) - length(initial_tag_log))
      {tag, new_logs}
    end)
    |> Enum.into(%{})
  end
end
