defmodule Freyja.Freer.EffectHandler do
  @moduledoc """
  Behavior for first-order effect handlers.

  EffectHandlers interpret first-order effects (Freer computations) during
  the interpretation phase. They are used by the Run module to execute effects.

  For higher-order effects (Hefty), see `Freyja.Hefty.Algebra` instead.
  """

  alias Freyja.Freer
  alias Freyja.RunOutcome
  alias Freyja.Run.RunState

  @doc """
  return true if this handler can handle the given effect. Handlers
  will be offered each effect in priority-queue order. If the handler
  returns :observer here, it will be given the effect, and may
  transform the effect and its own state, but the effect will continue to
  be offered to other handlers

  A Handler may choose to handle an effect, and return it unchanged
  - in which case the `updated_state` and `outputs` of the handler
  will be recorded, but the effect will continue to be offered to
  further EffectHandlers until one handles it and changes it

  The state parameter allows handlers to make stateful decisions about
  whether they will handle an effect (e.g., EffectLogger can check if
  it has a logged value to replay).
  """
  @callback handles?(computation :: Freyja.Freer.Impure.t(), state :: any) :: boolean | :observer

  @doc """
  called before a new computation (or nested computation) is run

  Offers an opportunity for Effect handlers to initialize their state,
  particularly when entering a nested computation (cf: EffectLogger)
  """
  @callback initialize(
              computation :: Freer.Impure.t(),
              handler_key :: atom,
              state :: any,
              run_state :: RunState.t()
            ) :: any

  @doc """
  interpret an Effect with the handler - the handler
  - handler_key - its key in the outputs
  - state - its state returned from its last invocation
  - outputs - the combined outputs of all handlers so far

  the function should return:

  `{effect, updated_state}`

  its `updated_state` will be retained and given to the next
  invocation of this handler

  """
  @callback interpret(
              computation :: Freer.Impure.t(),
              handler_key :: atom,
              state :: any,
              run_state :: RunState.t()
            ) :: {Freer.freer(), any}

  @doc """
  determines what to do with state from a scoped effect when
  that effect returns having completed successfully. If not provided
  then the default behaviour is to keep scoped state

  suspend returns from a scoped effect will not cause any change to the
  parent computation state - the scoped effect will be repeatedly resumed
  until a success or error return is reached
  """
  @callback scoped_ok(
              result :: any,
              value :: any,
              handler_key :: atom,
              state :: any,
              scoped_state :: any,
              run_outcome :: RunOutcome.t()
            ) :: any

  @doc """
  determines what to do with state from a scoped effect when
  that effect returns an error. If not provided then the default behaviour is
  to discard scoped state

  suspend returns from a scoped effect will not cause any change to the
  parent computation state - the scoped effect will be repeatedly resumed
  until a success or error return is reached
  """
  @callback scoped_error(
              result :: any,
              error :: any,
              handler_key :: atom,
              state :: any,
              scoped_state :: any,
              run_outcome :: RunOutcome.t()
            ) :: any

  @callback finalize(
              computation :: Freer.Pure.t(),
              handler_key :: atom,
              state :: any,
              run_state :: RunState.t()
            ) :: {Freer.Pure.t(), any}

  @optional_callbacks initialize: 4, scoped_ok: 6, scoped_error: 6, finalize: 4
end
