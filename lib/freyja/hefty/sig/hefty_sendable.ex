defmodule Freyja.Hefty.Sig.HeftySendable do
  @moduledoc """
  Use this module to make your struct module IHeftySendable.

  Similar to `Freyja.Freer.Sig.Sendable` for first-order effects, but for higher-order
  Hefty effect operations.

  ## Usage

      defmodule Freyja.Effects.Catch do
        defmodule Catch do
          defstruct [type: :any]

          use Freyja.Hefty.Sig.HeftySendable, sig: Freyja.Effects.Catch
        end
      end

  This implements `Freyja.Hefty.Sig.IHeftySendable` for the struct, which enables
  it to be used directly in `hefty` blocks without manual wrapping.

  ## What It Does

  Implements `IHeftySendable.send_to_hefty/1` to return the operation unchanged.
  This is appropriate for Hefty operation structs that are already meant to be
  used in Hefty computations.

  ## See Also

  - `Freyja.Freer.Sig.Sendable` - Similar module for first-order effects
  - `Freyja.Hefty.Sig.IHeftySendable` - The protocol this implements
  - `Freyja.Hefty.Sig.DefHeftyStruct` - Macro that uses this module
  """

  defmacro __using__(_opts) do
    quote do
      defimpl Freyja.Hefty.Sig.IHeftySendable, for: __MODULE__ do
        @moduledoc """
        Implementation of IHeftySendable for Hefty operation struct.

        Returns the operation unchanged, as it's already a valid Hefty operation.
        """

        def send_to_hefty(operation), do: operation
      end
    end
  end
end
