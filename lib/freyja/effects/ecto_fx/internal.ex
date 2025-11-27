if Code.ensure_loaded?(Ecto) do
  defmodule Freyja.Effects.EctoFx.Internal do
    @moduledoc """
    Internal effect operations for EctoFx.

    **This module is not part of the public API.** These operations are used
    internally by the EctoFx algebra to elaborate higher-order operations
    (transaction, capture) into first-order effects.

    Do not use these operations directly in application code - use the
    higher-order operations `EctoFx.transaction/2` and `EctoFx.capture/1` instead.
    """

    import Freyja.Freer.Sig.DefEffectStruct
    alias Freyja.Freer

    # Transaction control
    def_effect_struct(BeginTransaction, opts: [])
    def_effect_struct(CommitTransaction, [])
    def_effect_struct(RollbackTransaction, [])

    # Capture control
    def_effect_struct(BeginCapture, [])
    def_effect_struct(FinishCapture, ref: nil, mode: :commit)

    @typedoc "Repo operation options"
    @type opts :: keyword()

    @doc false
    @spec begin_transaction(opts()) :: Freer.t()
    def begin_transaction(opts \\ []) do
      %BeginTransaction{opts: opts}
      |> Freer.send_effect()
    end

    @doc false
    @spec commit_transaction() :: Freer.t()
    def commit_transaction do
      %CommitTransaction{}
      |> Freer.send_effect()
    end

    @doc false
    @spec rollback_transaction() :: Freer.t()
    def rollback_transaction do
      %RollbackTransaction{}
      |> Freer.send_effect()
    end

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
  end
end
