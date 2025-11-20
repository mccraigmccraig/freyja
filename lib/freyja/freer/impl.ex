defmodule Freyja.Freer.Impl do
  @moduledoc """
  Interpreter-facing implementation details for the Freer monad.
  Contains continuation-queue utilities and interpreter helpers.
  """
  require Logger

  alias Freyja.Freer
  alias Freyja.Freer.{Pure, Impure}
  alias Freyja.Freer.Sig.ISendable

  @doc """
  add a continuation `mf` to a queue of continuations `q`

  horribly inefficienrt - need to change queue representation
  to one that supports
   - append
   - prepend
   - concat
  with reasonable (log) amortized time - but a list is fine for now
  while developing the API
  """
  @spec q_append([(any -> any)], (any -> any)) :: [(any -> any)]
  def q_append(q, mf), do: Enum.concat(q, [mf])

  @doc """
  prepend a continuation `mf` to a queue of continuations `q`
  """
  @spec q_prepend([(any -> any)], (any -> any)) :: [(any -> any)]
  def q_prepend(q, mf), do: [mf | q]

  @doc """
  concatenate two queues of continuations
  """
  @spec q_concat([(any -> any)], [(any -> any)]) :: [(any -> any)]
  def q_concat(qa, qb), do: Enum.concat(qa, qb)

  @doc """
  apply value `x` to a queue `q` of continuations, returning a Freer value.
  Uses the Sendable.send protocol method to convert a plain effect value
  to a Freer - so effects can also be plain struct values with a
  Sendable.send implementation

  Applies a value through the list of continuations until it gets an %Impure{},
  then adds any remaining continuations from `q` to that %Impure{}'s queue.

  If an exception occurs during continuation application, it will be caught
  and converted to an Error effect (if Error handler is available in the current
  context).
  """
  @spec q_apply([(any -> Freer.freer())], any) :: Freer.freer()
  def q_apply(q, x) do
    case q do
      [k] ->
        try do
          neff = k.(x)
          # Logger.info("#{__MODULE__}.q_apply: #{inspect(neff, pretty: true)}")
          neff
        rescue
          exception ->
            handle_continuation_exception(exception, __STACKTRACE__)
        end

      [k | t] ->
        try do
          neff = k.(x)
          # Logger.info("#{__MODULE__}.q_apply: #{inspect(neff, pretty: true)}")
          bindp(neff, t)
        rescue
          exception ->
            handle_continuation_exception(exception, __STACKTRACE__)
        end
    end
  end

  # Handle exceptions from user code in continuations
  # Always converts to Throw effect - let Throw handler decide what to do
  # If no Throw handler is present, the effect will cause an unhandled effect error
  defp handle_continuation_exception(exception, stacktrace) do
    # Convert exception to serializable error
    error_data = Freyja.Freer.Exception.to_serializable(exception, stacktrace)

    # Create and return Throw effect
    Freyja.Effects.Throw.throw_error(error_data)
    |> ISendable.send()
  end

  # bind continuation queue `k` to Freer value `mx`, returning a new `Freer` value
  # with the continuation queues concatenated
  @spec bindp(Freer.freer(), [(any -> Freer.freer())]) :: Freer.freer()
  def bindp(mx, k) do
    case mx do
      %Pure{val: y} -> q_apply(k, y)
      %Impure{sig: sig, data: u, q: q} -> %Impure{sig: sig, data: u, q: q_concat(q, k)}
      sendable -> ISendable.send(sendable) |> bindp(k)
    end
  end

  # all the stuff below was for the first-order effects with
  # layered handlers - modelled afterfreer-simple - it's not used with
  # newer non-layered handler approach

  # @doc """
  # return a new continuation `x->Freer` which composes the
  # `(freer -> freer)` function `h` with the application of the queue `q`.
  # """
  # @spec q_comp([(any -> Freer.freer())], (Freer.freer() -> Freer.freer())) :: (any ->
  #                                                                                Freer.freer())
  # def q_comp(q, h), do: fn x -> q_apply(q, x) |> h.() end

  # # can the effect `eff` be handled ?
  # defp handles?(effs, eff) when is_list(effs), do: Enum.member?(effs, eff)
  # defp handles?(f, eff) when is_function(f, 1), do: f.(eff)

  # @doc """
  # Allows easy implementation of interpreters with `ret` and `h` functions.

  # handle_relay must return a Freer struct
  # """
  # @spec handle_relay(
  #         Freer.freer(),
  #         [atom],
  #         (any -> Freer.freer()),
  #         (any, (any -> Freer.freer()) ->
  #            Freer.freer())
  #       ) ::
  #         Freer.freer()
  # def handle_relay(%Pure{val: x}, _effs_or_fn, ret, _h), do: ret.(x)

  # def handle_relay(%Impure{sig: sig, data: u, q: q}, effs_or_fn, ret, h) do
  #   # a continuation including this handler
  #   k = q_comp(q, &handle_relay(&1, effs_or_fn, ret, h))

  #   if handles?(effs_or_fn, sig) do
  #     h.(u, k)
  #   else
  #     %Impure{sig: sig, data: u, q: [k]}
  #   end
  # end

  # @doc """
  # Allows easy implementation of interpreters which maintain state - such as the
  # classical State effect. Adapted from the freer-simple implementation
  # """
  # @spec handle_relay_s(
  #         Freer.freer(),
  #         [atom],
  #         any,
  #         (any -> Freer.freer()),
  #         (any, (any -> Freer.freer()) ->
  #            Freer.freer())
  #       ) ::
  #         Freer.freer()
  # def handle_relay_s(%Pure{val: x}, _effs_or_fn, initial_state, ret, _h),
  #   do: ret.(initial_state).(x)

  # def handle_relay_s(%Impure{sig: sig, data: u, q: q}, effs_or_fn, initial_state, ret, h) do
  #   # a continuation including this handler
  #   k = fn s -> q_comp(q, &handle_relay_s(&1, effs_or_fn, s, ret, h)) end

  #   if handles?(effs_or_fn, sig) do
  #     h.(initial_state).(u, k)
  #   else
  #     %Impure{sig: sig, data: u, q: [k.(initial_state)]}
  #   end
  # end
end
