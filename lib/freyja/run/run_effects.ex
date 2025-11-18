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


  @doc """
  A privileged operation used by Hefty algebras to propagate state changes
  from child computations (forks) to the parent's RunState.

  This is used by higher-order effect algebras (Catch, HeftyFxList, HeftyTaggedWriter)
  to implement non-transactional semantics - state changes persist even when
  errors occur or computations branch.

  NB: This is a privileged operation that can't be handled in a normal EffectHandler.
  It must be handled in Run because it can modify any EffectHandler's state.

  ## Parameters

  * `value` - The value to continue with in the parent computation
  * `run_outcome` - The outcome of the scoped computation, including result,
    effect states, and effect outputs

  ## See Also

  - `Freyja.Hefty.Effects.Catch.RunCatchingHandler` - Uses ScopedOk for state propagation
  - `Freyja.Hefty.Effects.HeftyFxList.Algebra` - Uses ScopedOk for fork results
  """
  def scoped_return(value, run_outcome),
    do: %ScopedOk{
      value: value,
      run_outcome: run_outcome
    }
end
