defmodule Freyja.Hefty.Sig.DefHeftyStruct do
  @moduledoc """
  Macro for defining higher-order effect operation structs.

  Similar to `Freyja.Freer.Sig.DefEffectStruct` but for Hefty (higher-order) effects.

  ## Differences from def_effect_struct

  - Does NOT implement `Freyja.Freer.Sig.Sendable` (higher-order ops can't be sent to Freer)
  - DOES implement `Freyja.Hefty.Sig.IHeftySendable` (via `HeftySendable`)
  - Creates struct definition with automatic protocol implementation
  - Adds documentation marking it as higher-order

  ## Usage

      defmodule Freyja.Hefty.Effects.Catch do
        import Freyja.Hefty.Sig.DefHeftyStruct

        # Higher-order operation
        def_hefty_struct(Catch, type: :any)

        # Convenience function for creating Catch operations
        def catch_hefty(try_comp, catch_comp) do
          Freyja.Hefty.send_hefty(
            __MODULE__,
            %Catch{type: :any},
            %{try: try_comp, catch: catch_comp}
          )
        end
      end

  ## Protocol Implementation

  The macro automatically adds `use Freyja.Hefty.Sig.HeftySendable` to the
  struct module, which implements `Freyja.Hefty.Sig.IHeftySendable` protocol.

  This allows Hefty operation structs to be used directly in `hefty` blocks:

      hefty do
        # Operation struct can be used directly
        x <- %Catch{type: :any}
        Hefty.pure(x)
      end

  The protocol implementation returns the operation unchanged, as it's already
  a valid Hefty operation.

  ## See Also

  - `Freyja.Freer.Sig.DefEffectStruct` - For first-order effects
  - `Freyja.Hefty.Algebra` - For elaboration algebras
  """

  @doc """
  Define a higher-order effect operation struct.

  Creates a module with a struct definition and moduledoc marking it as
  higher-order (must be elaborated before interpretation).

  ## Parameters

  - `name` - Module name for the operation struct
  - `fields` - Keyword list of struct fields with defaults

  ## Example

      def_hefty_struct(Catch, type: :any)

  Expands to:

      defmodule Catch do
        @moduledoc \"\"\"
        Higher-order operation struct.

        This operation must be elaborated to first-order effects before interpretation.
        See Freyja.Hefty.Algebra for elaboration.
        \"\"\"

        defstruct [type: :any]

        use Freyja.Hefty.Sig.HeftySendable
      end
  """
  defmacro def_hefty_struct(name, fields) do
    quote do
      defmodule unquote(name) do
        @moduledoc """
        Higher-order operation struct.

        This operation must be elaborated to first-order effects before interpretation.
        It cannot be sent directly to Freer - use `Freyja.Hefty.send_hefty` to create
        a Hefty.Impure node with computation parameters (forks).

        See `Freyja.Hefty.Algebra` for how to define elaboration algebras.
        """

        defstruct unquote(fields)

        use Freyja.Hefty.Sig.HeftySendable
      end
    end
  end
end
