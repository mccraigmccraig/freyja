defmodule Freyja.Effects.Changes do
  @moduledoc """
  General-purpose change capture effect.

  This effect provides a lightweight API for recording change events inside
  higher-order computations. Callers wrap a computation with `capture/1` and
  emit change events via `change/1` (or `change/2` for `{old, new}` tuples).

  ## Operations

    * `change(change)` – First-order operation that records a change value for
      the current capture scope.
    * `capture(computation)` – Higher-order operation that runs a Hefty
      computation, accumulates all `change/1` values produced within it, and
      returns `{result, captured_changes}`.

  A single capture scope may be active at a time. Attempting to nest captures
  raises an `ArgumentError`, preventing double recording of inner scopes.

  ## Example

      import Freyja.Syntax

      defhefty process_batch(rows) do
        {updated_rows, changes} <-
          Changes.capture(FxList.fx_map(rows, &process_row/1))

        _ <- Lift.lift(Storage.apply_changes(changes))
        return(%{rows: updated_rows, changes: changes})
      end
  """

  import Freyja.Freer.Sig.DefEffectStruct
  import Freyja.Hefty.Sig.DefHeftyStruct

  alias Freyja.Freer

  def_effect_struct(Change, change: nil)
  def_effect_struct(BeginCapture, [])
  def_effect_struct(FinishCapture, ref: nil, mode: :commit)

  def_hefty_struct(Capture, [])

  @typedoc "Arbitrary change payload"
  @type change :: any()

  @doc """
  Emit a change value for the active capture scope.
  """
  @spec change(change()) :: Freer.t()
  def change(value) do
    %Change{change: value}
    |> Freer.send_effect()
  end

  @doc """
  Convenience helper that records `{old, new}` tuples.
  """
  @spec change(any(), any()) :: Freer.t()
  def change(old, new), do: change({old, new})

  @doc false
  @spec begin_capture() :: Freer.t()
  def begin_capture do
    %BeginCapture{}
    |> Freer.send_effect()
  end

  @doc false
  @spec finish_capture(non_neg_integer(), :commit | :abort) :: Freer.t()
  def finish_capture(ref, mode) when mode in [:commit, :abort] do
    %FinishCapture{ref: ref, mode: mode}
    |> Freer.send_effect()
  end

  @doc """
  Run a computation while capturing change events under `tag`.

  Returns `{result, captured_changes}` where `result` is the computation result
  and `captured_changes` is the ordered list of values passed to `change/1`
  within this scope.
  """
  @spec capture(Freyja.Hefty.t()) :: Freyja.Hefty.t()
  def capture(computation) do
    Freyja.Hefty.send_hefty(
      __MODULE__,
      %Capture{},
      %{inner: computation}
    )
  end
end

defmodule Freyja.Effects.Changes.Handler do
  @moduledoc """
  Handler for the `Freyja.Effects.Changes` first-order operations.

  Internally maintains a stack of active capture contexts. Each context records
  a tag and the list of emitted change values. The handler also exposes a
  summary in its final output: `%{captures: %{tag => [[changes] ...]}}`.
  """

  @behaviour Freyja.Freer.EffectHandler

  alias Freyja.Effects.Changes
  alias Freyja.Effects.Changes.{BeginCapture, Change, FinishCapture}
  alias Freyja.Freer.Impl
  alias Freyja.Freer.Impure
  alias Freyja.Run.RunState

  defmodule State do
    @moduledoc false
    @enforce_keys [:next_ref, :active]
    defstruct next_ref: 1, active: nil
  end

  @impl true
  def default_initial_state,
    do: %State{next_ref: 1, active: nil}

  @impl true
  def handles?(%Impure{sig: sig}, _state), do: sig == Changes

  @impl true
  def interpret(
        %Impure{sig: Changes, data: op, q: q},
        _handler_key,
        %State{} = state,
        %RunState{}
      ) do
    case op do
      %Change{change: value} ->
        new_state = record_change(state, value)
        {Impl.q_apply(q, :ok), new_state}

      %BeginCapture{} ->
        {ref, new_state} = start_capture(state)
        {Impl.q_apply(q, ref), new_state}

      %FinishCapture{ref: ref, mode: mode} ->
        {result, new_state} = finish_capture(state, ref, mode)
        {Impl.q_apply(q, result), new_state}
    end
  end

  @doc """
  Add the handler to a pipeline.
  """
  def run(computation_or_builder, initial_state \\ :__default__) do
    Freyja.Run.RunBuilder.add(computation_or_builder, __MODULE__, initial_state)
  end

  defp record_change(%State{active: nil}, _value) do
    raise RuntimeError, "Changes.change/1 called without an active capture"
  end

  defp record_change(%State{active: %{changes: changes} = ctx} = state, value) do
    updated_context = %{ctx | changes: [value | changes]}
    %State{state | active: updated_context}
  end

  defp start_capture(%State{active: %{}}) do
    raise ArgumentError, "Changes.capture is already active"
  end

  defp start_capture(%State{next_ref: ref} = state) do
    context = %{ref: ref, changes: []}
    {ref, %State{state | next_ref: ref + 1, active: context}}
  end

  defp finish_capture(%State{active: nil}, _ref, _mode) do
    raise ArgumentError, "Changes.capture stack underflow"
  end

  defp finish_capture(%State{active: %{ref: active_ref}} = _state, ref, _mode)
       when ref != active_ref do
    raise ArgumentError,
          "Changes.capture closed out of order: expected ref #{active_ref}, got #{ref}"
  end

  defp finish_capture(%State{active: %{changes: changes}} = state, _ref, mode)
       when mode in [:commit, :abort] do
    case mode do
      :commit ->
        committed = Enum.reverse(changes)

        {committed, %State{state | active: nil}}

      :abort ->
        {[], %State{state | active: nil}}
    end
  end
end

defmodule Freyja.Effects.Changes.Algebra do
  @moduledoc """
  Hefty algebra that elaborates `Changes.capture/1` into first-order operations.

  Captures are implemented by:

    1. Emitting `begin_capture/0` to push a new context on the handler stack.
    2. Interposing on `Throw.throw_error/1` so that abort cleanup runs when
       errors escape the scope.
    3. Running the inner computation.
    4. Emitting `finish_capture/2` with `:commit` to obtain the captured changes.

  The elaborated Freer computation returns `{result, captured_changes}` and
  guarantees that handler state is restored even if the computation throws.
  """

  @behaviour Freyja.Hefty.Algebra

  use Freyja.Syntax

  alias Freyja.Effects.{Changes, Throw}
  alias Freyja.Effects.Changes.Capture
  alias Freyja.Effects.Throw.ThrowOp
  alias Freyja.Freer.Interpose

  @impl true
  def handles?(sig) when sig == Freyja.Effects.Changes, do: true
  def handles?(_), do: false

  @impl true
  def elaborate(%Capture{}, psi, k, _elaborator) do
    inner = Map.fetch!(psi, :inner)

    con do
      ref <- Changes.begin_capture()

      guarded_inner = attach_abort_on_throw(inner, ref)

      result <- guarded_inner
      changes <- Changes.finish_capture(ref, :commit)
      k.({result, changes})
    end
  end

  defp attach_abort_on_throw(inner, ref) do
    Interpose.interpose_with(inner, Freyja.Effects.Throw, fn %ThrowOp{error: err}, _cont ->
      con do
        _ <- Changes.finish_capture(ref, :abort)
        Throw.throw_error(err)
      end
    end)
  end

  @doc """
  Add the algebra to a pipeline.
  """
  def run(computation_or_builder) do
    Freyja.Run.RunBuilder.add(computation_or_builder, __MODULE__, nil)
  end
end
