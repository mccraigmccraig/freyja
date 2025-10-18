defmodule Freyja.Sig.DefEffectStruct do
  @moduledoc """
  the def_effect_stfuct macro to define an effect
  signature struct and make it ISendable in a single
  call
  """
  defmacro def_effect_struct(mod, struct_args \\ []) do
    sig = __CALLER__.module

    quote do
      defmodule unquote(mod) do
        use Freyja.Sig.Sendable, sig: unquote(sig)
        defstruct unquote(struct_args)
      end
    end
  end
end
