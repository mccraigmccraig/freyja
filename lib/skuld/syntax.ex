defmodule Skuld.Syntax do
  @moduledoc """
  Unified syntax module providing do-notation macros for Skuld computations.

  ## Usage

      import Skuld.Syntax

      # Now you have access to:
      # - comp (inline computation block)
      # - defcomp, defcompp (function definitions)

  Or use `use Skuld.Syntax` to import all macros:

      use Skuld.Syntax

  ## Example

      import Skuld.Syntax
      alias Skuld.Effects.State

      comp do
        x <- State.get()
        y = x + 1
        _ <- State.put(y)
        return(y)
      end

  ## Defining Functions

      defcomp increment() do
        x <- State.get()
        _ <- State.put(x + 1)
        return(x + 1)
      end

      defcompp private_helper() do
        ctx <- Reader.ask()
        return(ctx.value)
      end

  ## Syntax Reference

  - `x <- effect()` - bind the result of an effectful computation
  - `x = expr` - pure variable binding (unchanged)
  - `return(value)` - lift a pure value into a computation
  - Last expression is the final computation (must be a computation)

  ## See Also

  - `Skuld.Comp.CompBlock` - macro implementation details
  - `Skuld.Comp` - core computation primitives
  """

  defmacro __using__(_opts) do
    quote do
      import Skuld.Comp.CompBlock
    end
  end
end
