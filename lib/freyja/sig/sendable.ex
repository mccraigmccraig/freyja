defmodule Freyja.Sig.Sendable do
  @moduledoc """
  use this module to make your struct module ISendable
  """
  defmacro __using__(opts) do
    sig = Keyword.get(opts, :sig)

    quote do
      defimpl Freyja.Sig.ISendable, for: __MODULE__ do
        def send(eff),
          do: Freyja.Freer.send_effect(eff, unquote(sig))
      end
    end
  end
end
