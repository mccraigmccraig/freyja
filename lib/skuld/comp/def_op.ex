defmodule Skuld.Comp.DefOp do
  @moduledoc """
  Macro for defining serializable operation structs.

  Defines a struct module with Jason.Encoder implementation for
  JSON serialization via `Skuld.Comp.SerializableStruct`.

  ## Example

      defmodule Skuld.Effects.State do
        import Skuld.Comp.DefOp

        def_op Get
        def_op Put, [:value]

        # Creates:
        # - Skuld.Effects.State.Get with defstruct []
        # - Skuld.Effects.State.Put with defstruct [:value]
        # - Jason.Encoder implementations for both
      end

  The structs can then be used as effect arguments:

      def get, do: Skuld.Comp.effect(@sig, %Get{})
      def put(value), do: Skuld.Comp.effect(@sig, %Put{value: value})

  And serialized to JSON:

      Jason.encode!(%State.Put{value: 42})
      # => {"__struct__":"Elixir.Skuld.Effects.State.Put","value":42}
  """

  @doc """
  Define an operation struct with JSON serialization.

  ## Arguments

  - `mod` - the module name (will be nested under the calling module)
  - `fields` - list of struct fields (default: [])
  """
  defmacro def_op(mod, fields \\ []) do
    quote do
      defmodule unquote(mod) do
        defstruct unquote(fields)
      end

      defimpl Jason.Encoder, for: unquote(mod) do
        def encode(value, opts) do
          value
          |> Skuld.Comp.SerializableStruct.encode()
          |> Jason.Encode.map(opts)
        end
      end
    end
  end
end
