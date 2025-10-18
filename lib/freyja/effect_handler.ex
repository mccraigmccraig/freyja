defmodule Freyja.EffectHandler do
  @moduledoc """
  The Run module uses EffectHandlers to interpret
  effects when running a computation
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
  """
  @callback handles?(computation :: Freer.Impure.t()) :: boolean | :observer

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
  that effect returns. If not provided then the default behaviour is
  to
  - keep scoped state on a successful return
  - discard scoped state on an error return
  - not sure yet on a suspend return - suspending from within a scoped effect
    seems like it might require some extra thought - perhaps wrapping the
    scoped suspend in an outer suspend - not sure how that works with
    logging at all
  """
  @callback scoped_return(
              result :: Freyja.Result.result(),
              computation :: Freyja.Freer.freer(),
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

  @optional_callbacks initialize: 4, scoped_return: 6, finalize: 4
end
