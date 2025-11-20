#!/usr/bin/env elixir

# Example demonstrating the new catch clause support in hefty macros
#
# Run with: mix run examples/hefty_catch_example.exs

import Freyja.HeftyMacro

alias Freyja.Run
alias Freyja.Effects.Lift
alias Freyja.Effects.Catch
alias Freyja.Effects.Throw
alias Freyja.Effects.Throw.Handler, as: ThrowHandler
alias Freyja.Effects.State

# Example 1: Simple catch with single pattern
IO.puts("Example 1: Simple catch with single pattern")

computation1 =
  hefty do
    x <- State.get()

    if x < 0 do
      Throw.throw_error("negative value")
    else
      return(x * 2)
    end
  catch
    "negative value" -> return(0)
  end

# Success case
outcome1a =
  Run.run(
    computation1,
    [Catch.Algebra, Lift.Algebra],
    [State.Handler, ThrowHandler, Catch.RunCatchingHandler],
    %{State.Handler => 5}
  )

IO.puts("  Success (x=5): #{inspect(outcome1a.result)}")

# Error case (caught)
outcome1b =
  Run.run(
    computation1,
    [Catch.Algebra, Lift.Algebra],
    [State.Handler, ThrowHandler, Catch.RunCatchingHandler],
    %{State.Handler => -3}
  )

IO.puts("  Error caught (x=-3): #{inspect(outcome1b.result)}")

# Example 2: Multiple catch patterns
IO.puts("\nExample 2: Multiple catch patterns")

computation2 =
  hefty do
    error_type <- State.get()

    case error_type do
      :throw_negative -> Throw.throw_error("negative")
      :throw_overflow -> Throw.throw_error("overflow")
      value -> return(value)
    end
  catch
    "negative" -> return(:handled_negative)
    "overflow" -> return(:handled_overflow)
  end

# Test different error types
for {input, _expected} <- [
      {:throw_negative, :handled_negative},
      {:throw_overflow, :handled_overflow},
      {42, 42}
    ] do
  outcome =
    Run.run(
      computation2,
      [Catch.Algebra, Lift.Algebra],
      [State.Handler, ThrowHandler, Catch.RunCatchingHandler],
      %{State.Handler => input}
    )

  IO.puts("  Input: #{inspect(input)}, Result: #{inspect(outcome.result)}")
end

# Example 3: Catch-all pattern
IO.puts("\nExample 3: Catch-all pattern")

computation3 =
  hefty do
    Throw.throw_error({:custom, :error, 123})
  catch
    error -> return({:caught, error})
  end

outcome3 =
  Run.run(
    computation3,
    [Catch.Algebra, Lift.Algebra],
    [ThrowHandler, Catch.RunCatchingHandler]
  )

IO.puts("  Result: #{inspect(outcome3.result)}")

# Example 4: Using defhefty with catch
IO.puts("\nExample 4: Using defhefty with catch")

defmodule SafeMath do
  import Freyja.HeftyMacro
  alias Freyja.Effects.Throw

  defhefty safe_divide(a, b) do
    if b == 0 do
      Throw.throw_error(:division_by_zero)
    else
      return(div(a, b))
    end
  catch
    :division_by_zero -> return(:infinity)
  end
end

# Success case
result1 = SafeMath.safe_divide(10, 2)

outcome4a =
  Run.run(
    result1,
    [Catch.Algebra, Lift.Algebra],
    [ThrowHandler, Catch.RunCatchingHandler]
  )

IO.puts("  10 / 2 = #{inspect(outcome4a.result)}")

# Error case
result2 = SafeMath.safe_divide(10, 0)

outcome4b =
  Run.run(
    result2,
    [Catch.Algebra, Lift.Algebra],
    [ThrowHandler, Catch.RunCatchingHandler]
  )

IO.puts("  10 / 0 = #{inspect(outcome4b.result)}")

# Example 5: Re-throwing unmatched errors
IO.puts("\nExample 5: Re-throwing unmatched errors")

computation5 =
  hefty do
    Throw.throw_error("unhandled")
  catch
    "handled" -> return(:ok)
  end

outcome5 =
  Run.run(
    computation5,
    [Catch.Algebra, Lift.Algebra],
    [ThrowHandler, Catch.RunCatchingHandler]
  )

IO.puts("  Result (should be error): #{inspect(outcome5.result)}")

IO.puts("\nAll examples completed!")
