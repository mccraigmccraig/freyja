defmodule Skuld.Effects.Throw do
  @moduledoc """
  Throw/Catch effects - error handling with scoped catching.

  Uses the `%Skuld.Throw{}` struct as the error result type, which
  is intercepted by `catch_error` via leave_scope.

  ## Architecture

  - `throw(error)` returns `%Throw{error: error}` as the result
  - `catch_error` installs a leave_scope that intercepts `%Throw{}` results
  - When caught, the leave_scope runs the recovery computation
  - Normal completion is wrapped in `{:ok, value}`
  """

  @behaviour Skuld.IHandler

  import Skuld.DefOp

  alias Skuld
  alias Skuld.Env

  @sig __MODULE__

  #############################################################################
  ## Operation Structs
  #############################################################################

  def_op(ThrowOp, [:error])

  #############################################################################
  ## Operations
  #############################################################################

  @doc "Throw an error - does not resume"
  @spec throw(term()) :: Skuld.computation()
  def throw(error) do
    Skuld.effect(@sig, %ThrowOp{error: error})
  end

  @doc """
  Catch errors from a sub-computation.

  If the sub-computation throws, the error handler is invoked.
  If it completes normally, the result is wrapped in {:ok, value}.
  """
  @spec catch_error(Skuld.computation(), (term() -> Skuld.computation())) :: Skuld.computation()
  def catch_error(comp, error_handler) do
    fn env, outer_k ->
      previous_leave_scope = Env.get_leave_scope(env)

      catch_leave_scope = fn result, inner_env ->
        case result do
          %Skuld.Throw{error: error} ->
            # CAUGHT! Restore previous leave_scope and run recovery
            restored_env = Env.with_leave_scope(inner_env, previous_leave_scope)

            # Run recovery computation - it returns {result, env}
            {recovery_result, recovery_env} =
              error_handler.(error).(restored_env, fn v, e -> {v, e} end)

            # Recovery's result goes through previous leave_scope chain
            previous_leave_scope.(recovery_result, recovery_env)

          other ->
            # Normal completion - wrap in {:ok, ...} and continue chain
            previous_leave_scope.({:ok, other}, inner_env)
        end
      end

      modified_env = Env.with_leave_scope(env, catch_leave_scope)
      comp.(modified_env, outer_k)
    end
  end

  @doc "Catch and return Either-style result"
  @spec try_catch(Skuld.computation()) :: Skuld.computation()
  def try_catch(comp) do
    catch_error(comp, fn error -> Skuld.pure({:error, error}) end)
  end

  #############################################################################
  ## Handler Installation
  #############################################################################

  @doc """
  Install the default Throw handler.

  The default handler returns a `%Skuld.Throw{}` struct as the result.
  """
  @spec handler(Skuld.env()) :: Skuld.env()
  def handler(env) do
    Env.with_handler(env, @sig, &__MODULE__.handle/3)
  end

  #############################################################################
  ## IHandler Implementation
  #############################################################################

  @doc "Default handler - return Throw struct as result (does not call k)"
  @impl Skuld.IHandler
  def handle(%ThrowOp{error: error}, env, _k) do
    {%Skuld.Throw{error: error}, env}
  end
end
