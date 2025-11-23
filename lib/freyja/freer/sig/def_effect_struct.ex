defmodule Freyja.Freer.Sig.DefEffectStruct do
  @moduledoc """
  the def_effect_stfuct macro to define an effect
  signature struct and make it ISendable in a single
  call
  """
  defmacro def_effect_struct(mod, struct_args \\ []) do
    sig = __CALLER__.module

    quote do
      defmodule unquote(mod) do
        use Freyja.Freer.Sig.Sendable, sig: unquote(sig)
        defstruct unquote(struct_args)
      end

      defimpl Jason.Encoder, for: unquote(mod) do
        def encode(value, opts) do
          value
          |> Freyja.Run.SerializableStruct.encode()
          |> Jason.Encode.map(opts)
        end
      end
    end
  end
end
