defmodule Freyja.Run.RunEffects do
  @moduledoc """
  blessed effect signature describing how a scoped computation
  result is to be handled in the parent computation
  """
  defmodule ScopedOk do
    @moduledoc """
    computation: the effect describing how the scoped
      computation is to be handled
    run_outcome: the scoped computation result
    """
    use Freyja.Freer.Sig.Sendable, sig: Freyja.Run.RunEffects

    defstruct value: nil, run_outcome: nil

    @type t :: %__MODULE__{
            value: any,
            run_outcome: Freyja.RunOutcome.t()
          }
  end

  defmodule ScopedError do
    use Freyja.Freer.Sig.Sendable, sig: Freyja.Run.RunEffects

    defstruct error: nil, run_outcome: nil

    @type t :: %__MODULE__{
            error: any,
            run_outcome: Freyja.RunOutcome.t()
          }
  end

  @doc """
  A privileged operation which allows scoped effects like
  Error to return the effect states of a child computation to the
  parent's RunState, along with a computation to continue with

  NB: this is a privileged operation which can't be handled in
  a normal EffectHandler and must be handled in Run - because it
  can involve modification of any EffectHandler's state, not just the
  EffectHandler's own state

  * computation - a Pure or Impure which the scoping handler can use
    to achieve anything (continue, return an error &c) once the
    effect states have been updated
  * run_outcome - the outcome of the scoped computation, including
      the result, the effect states and the effect outputs
  """
  def scoped_return(value, run_outcome),
    do: %ScopedOk{
      value: value,
      run_outcome: run_outcome
    }

  def scoped_error(error, run_outcome),
    do: %ScopedError{
      error: error,
      run_outcome: run_outcome
    }
end
