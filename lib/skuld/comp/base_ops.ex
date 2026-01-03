defmodule Skuld.Comp.BaseOps do
  @moduledoc """
  Base operations automatically imported into `comp` blocks.

  Currently provides:
  - `return/1` - lift a pure value into a computation (alias for `Skuld.Comp.pure/1`)
  """

  @doc """
  Lift a pure value into a computation.

  This is an alias for `Skuld.Comp.pure/1`, provided for ergonomic use
  in `comp` blocks where `return(value)` reads more naturally.

  ## Example

      comp do
        x <- State.get()
        return(x + 1)
      end
  """
  @spec return(term()) :: Skuld.Comp.Types.computation()
  def return(x), do: Skuld.Comp.pure(x)
end
