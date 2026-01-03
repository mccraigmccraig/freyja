defmodule Skuld.Comp.Types do
  @moduledoc """
  Type definitions for Skuld.Comp.

  These types define the core abstractions of the evidence-passing effect system.
  """

  @typedoc "Any result value - opaque to the framework"
  @type result :: term()

  @typedoc "Effect signature - identifies which handler handles an operation"
  @type sig :: atom()

  @typedoc "The environment carrying evidence, state, and leave-scope"
  @type env :: Skuld.Comp.Env.t()

  @typedoc "A handler interprets effect operations"
  @type handler :: (args :: term(), env(), k() -> {result(), env()})

  @typedoc "Continuation after an effect"
  @type k :: (term(), env() -> {result(), env()})

  @typedoc "A computation awaiting execution"
  @type computation :: (env(), k() -> {result(), env()})

  @typedoc "Leave-scope handler - cleans up or redirects"
  @type leave_scope :: (result(), env() -> {result(), env()})
end
