defmodule Freyja.Freer.Sig.DefEffectStruct do
  @moduledoc """
  The def_effect_struct macro to define an effect signature struct
  with ISignature implementation for signature lookup.
  """
  defmacro def_effect_struct(mod, struct_args \\ []) do
    sig = __CALLER__.module

    quote do
      defmodule unquote(mod) do
        use Freyja.Freer.Sig.Signature, sig: unquote(sig)
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
