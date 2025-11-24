defmodule Freyja.Freer.Sig.Signature do
  @moduledoc """
  use this module to let your structs expose their signature atom
  """
  defmacro __using__(opts) do
    sig = Keyword.get(opts, :sig)

    quote do
      defimpl Freyja.Freer.Sig.ISignature, for: __MODULE__ do
        def signature(eff),
          do: unquote(sig)
      end
    end
  end
end
