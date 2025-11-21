defmodule Freyja.Effects.BracketTest do
  use ExUnit.Case

  use Freyja.Syntax

  alias Freyja.Effects.Bracket
  alias Freyja.Effects.Coroutine
  alias Freyja.Effects.Lift
  alias Freyja.Effects.State
  alias Freyja.Effects.Throw
  alias Freyja.Run

  describe "Bracket - basic success path" do
    test "acquires, uses, and releases resource" do
      # Track what operations occurred
      computation =
        hefty do
          result <-
            Bracket.bracket(
              hefty do
                # Acquire
                _u1 <- State.put([:acquired])
                return(:resource)
              end,
              fn _resource ->
                # Release
                hefty do
                  log <- State.get()
                  _u2 <- State.put(log ++ [:released])
                  return(:ok)
                end
              end,
              fn resource ->
                # Use
                hefty do
                  log <- State.get()
                  _u3 <- State.put(log ++ [:used])
                  return({:result, resource})
                end
              end
            )

          log <- State.get()
          return({result, log})
        end

      outcome =
        Run.run(
          computation,
          [Bracket.Algebra, Freyja.Effects.Catch.Algebra, Lift.Algebra],
          [State.Handler, Throw.Handler],
          %{State.Handler => []}
        )

      # Result should be {:ok, {:result, :resource}}
      # Log should show: acquired, used, released
      assert {:ok, {{:result, :resource}, [:acquired, :used, :released]}} = outcome.result
    end

    test "release runs exactly once on success" do
      computation =
        hefty do
          result <-
            Bracket.bracket(
              hefty do
                return(:resource)
              end,
              fn _resource ->
                hefty do
                  # Increment counter on release
                  count <- State.get()
                  _u <- State.put(count + 1)
                  return(:ok)
                end
              end,
              fn resource ->
                hefty do
                  return({:used, resource})
                end
              end
            )

          count <- State.get()
          return({result, count})
        end

      outcome =
        Run.run(
          computation,
          [Bracket.Algebra, Freyja.Effects.Catch.Algebra, Lift.Algebra],
          [State.Handler, Throw.Handler],
          %{State.Handler => 0}
        )

      # Release should run exactly once
      assert {:ok, {{:used, :resource}, 1}} = outcome.result
    end
  end

  describe "Bracket - error handling" do
    test "releases resource when use throws error" do
      computation =
        hefty do
          result <-
            Freyja.Effects.Catch.catch_hefty(
              hefty do
                Bracket.bracket(
                  hefty do
                    # Acquire
                    _u1 <- State.put([:acquired])
                    return(:resource)
                  end,
                  fn _resource ->
                    # Release
                    hefty do
                      log <- State.get()
                      _u2 <- State.put(log ++ [:released])
                      return(:ok)
                    end
                  end,
                  fn _resource ->
                    # Use - throws error
                    hefty do
                      log <- State.get()
                      _u3 <- State.put(log ++ [:used])
                      Lift.lift(Throw.throw_error(:boom))
                    end
                  end
                )
              end,
              fn err ->
                hefty do
                  return({:caught, err})
                end
              end
            )

          log <- State.get()
          return({result, log})
        end

      outcome =
        Run.run(
          computation,
          [Bracket.Algebra, Freyja.Effects.Catch.Algebra, Lift.Algebra],
          [State.Handler, Throw.Handler],
          %{State.Handler => []}
        )

      # Release should run before error is caught
      # Log should show: acquired, used, released
      assert {:ok, {{:caught, :boom}, [:acquired, :used, :released]}} = outcome.result
    end
  end

  describe "Bracket - with suspensions" do
    test "releases after suspension and resume" do
      computation =
        hefty do
          result <-
            Bracket.bracket(
              hefty do
                _u1 <- State.put([:acquired])
                return(:resource)
              end,
              fn _resource ->
                hefty do
                  log <- State.get()
                  _u2 <- State.put(log ++ [:released])
                  return(:ok)
                end
              end,
              fn resource ->
                hefty do
                  log <- State.get()
                  _u3 <- State.put(log ++ [:before_yield])

                  # Suspend
                  resume_value <- Coroutine.yield({:yielded, resource})

                  log2 <- State.get()
                  _u4 <- State.put(log2 ++ [:after_resume])

                  return({:result, resource, resume_value})
                end
              end
            )

          log <- State.get()
          return({result, log})
        end

      # Initial run - suspends
      outcome =
        Run.run(
          computation,
          [Bracket.Algebra, Freyja.Effects.Catch.Algebra, Lift.Algebra],
          [State.Handler, Throw.Handler, Coroutine.Handler],
          %{State.Handler => []}
        )

      # Should suspend, release has NOT run yet
      assert {:suspend, {:yielded, :resource}, _continuation} = outcome.result
      assert [:acquired, :before_yield] = outcome.outputs[State.Handler]

      # Resume
      outcome2 = Run.resume(outcome, :resumed_value)

      # After resume, release should run
      assert {:done, {:ok, {{:result, :resource, :resumed_value}, log}}} = outcome2.result
      assert [:acquired, :before_yield, :after_resume, :released] = log
    end
  end
end
