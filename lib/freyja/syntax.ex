defmodule Freyja.Syntax do
  @moduledoc """
  Unified syntax module providing all do-notation macros for both Freer and Hefty computations.

  This module re-exports macros from both `Freyja.Freer.FreerBlock` (for first-order effects)
  and `Freyja.Hefty.HeftyBlock` (for higher-order effects), providing a single import point.

  ## Usage

      import Freyja.Syntax

      # Now you have access to all macros:
      # - con, defcon, defconp (for Freer computations)
      # - hefty, defhefty, defheftyp (for Hefty computations)

  Alternatively, use `use Freyja.Syntax` to import all macros at once.

  ## Usage with use

      use Freyja.Syntax

  ## Freer Macros (First-Order Effects)

  Use `con` and `defcon` for computations with only first-order effects like State, Reader, Writer:

      con [State, Writer] do
        x <- State.get()
        _ <- Writer.tell("got: \#{x}")
        State.put(x + 1)
        return(x)
      end

  ## Hefty Macros (Higher-Order Effects)

  Use `hefty` and `defhefty` for computations with higher-order effects like Catch, FxList:

      hefty do
        result <- Catch.catch_hefty(
          hefty do
            x <- Lift.lift(State.get())
            if x < 0, do: Lift.lift(Throw.throw_error("negative"))
            return(x * 2)
          end,
          fn _err -> return(0) end
        )
        return(result)
      end

  ## Mixing Both

  Often you'll use both types of computations together. Hefty computations can contain
  Freer computations via the `Lift` effect:

      defhefty safe_computation() do
        result <- Catch.catch_hefty(
          Lift.lift(my_freer_computation()),  # con block
          fn _err -> return(:error) end
        )
        return(result)
      end

      defcon my_freer_computation, [State] do
        x <- State.get()
        return(x * 2)
      end

  ## See Also

  - `Freyja.Freer.FreerBlock` - Freer do-notation macros
  - `Freyja.Hefty.HeftyBlock` - Hefty do-notation macros
  """

  defmacro __using__(_opts) do
    quote do
      import Freyja.Freer.FreerBlock, except: [return: 1]
      import Freyja.Hefty.HeftyBlock, except: [return: 1]
    end
  end
end
