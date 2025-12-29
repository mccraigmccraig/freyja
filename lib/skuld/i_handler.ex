defmodule Skuld.IHandler do
  @moduledoc """
  Behaviour for effect handlers in Skuld.

  Implementing this behaviour provides:
  - LSP autocomplete for the `handle/3` callback signature
  - Compile-time warnings if the callback is missing or has wrong arity
  - Public `handle/3` function that can be referenced as `&Module.handle/3`

  ## Example

      defmodule MyEffect do
        @behaviour Skuld.IHandler

        @impl Skuld.IHandler
        def handle(:op, env, k) do
          k.(:result, env)
        end
      end

      # Install handler:
      env |> Env.with_handler(MyEffect, &MyEffect.handle/3)
  """

  @doc """
  Handle an effect operation.

  Receives:
  - `args` - the operation arguments (e.g., `:get`, `{:put, value}`)
  - `env` - the current environment
  - `k` - the continuation to invoke with the result

  Must return `{result, env}` - either by calling `k.(value, env)` or
  by returning a sentinel like `{%Skuld.Throw{}, env}`.
  """
  @callback handle(args :: term(), env :: Skuld.env(), k :: Skuld.k()) ::
              {Skuld.result(), Skuld.env()}
end
