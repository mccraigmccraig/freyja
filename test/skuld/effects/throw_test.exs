defmodule Skuld.Effects.ThrowTest do
  use ExUnit.Case, async: true

  alias Skuld.Comp
  alias Skuld.Effects.State
  alias Skuld.Effects.Throw

  describe "throw" do
    test "produces Throw result" do
      comp = Throw.throw(:boom)

      {result, _env} =
        comp
        |> Throw.with_handler()
        |> Comp.run()

      assert %Comp.Throw{error: :boom} = result
    end

    test "short-circuits computation" do
      # Computation that sets state, then throws
      comp =
        Comp.bind(State.put(1), fn _ ->
          Comp.bind(Throw.throw(:error), fn _ ->
            # Never reached
            State.put(2)
          end)
        end)

      {result, _env} =
        comp
        |> State.with_handler(0)
        |> Throw.with_handler()
        |> Comp.run()

      # Result is the Throw sentinel
      assert %Comp.Throw{error: :error} = result
    end
  end

  describe "catch_error" do
    test "catches thrown errors" do
      comp =
        Throw.catch_error(
          Throw.throw(:my_error),
          fn error -> Comp.pure({:caught, error}) end
        )

      {result, _env} =
        comp
        |> Throw.with_handler()
        |> Comp.run()

      assert {:caught, :my_error} = result
    end

    test "passes through normal completion unchanged" do
      comp =
        Throw.catch_error(
          Comp.pure(42),
          fn error -> Comp.pure({:caught, error}) end
        )

      {result, _env} =
        comp
        |> Throw.with_handler()
        |> Comp.run()

      # No {:ok, ...} wrapping - value passes through unchanged
      assert result == 42
    end

    test "recovery continues through normal flow (bind receives value)" do
      inner =
        Throw.catch_error(
          Throw.throw(:error),
          fn _e -> Comp.pure(:recovered) end
        )

      outer =
        Comp.bind(inner, fn result ->
          Comp.pure({:got, result})
        end)

      {result, _env} =
        outer
        |> Throw.with_handler()
        |> Comp.run()

      # Recovery value flows through bind
      assert {:got, :recovered} = result
    end

    test "nested catch - inner catches first" do
      comp =
        Throw.catch_error(
          Throw.catch_error(
            Throw.throw(:inner_error),
            fn e -> Comp.pure({:inner_caught, e}) end
          ),
          fn e -> Comp.pure({:outer_caught, e}) end
        )

      {result, _env} =
        comp
        |> Throw.with_handler()
        |> Comp.run()

      # Inner catches, recovery flows through, no wrapping
      assert {:inner_caught, :inner_error} = result
    end

    test "re-thrown error propagates to outer catch" do
      # Inner handler explicitly re-throws unhandled errors
      inner_handler = fn
        :different -> Comp.pure(:inner_caught)
        other -> Throw.throw(other)
      end

      outer_handler = fn
        :the_error -> Comp.pure(:outer_caught)
        other -> Throw.throw(other)
      end

      comp =
        Throw.catch_error(
          Throw.catch_error(
            Throw.throw(:the_error),
            inner_handler
          ),
          outer_handler
        )

      {result, _env} =
        comp
        |> Throw.with_handler()
        |> Comp.run()

      # Inner doesn't match, re-throws, outer catches
      assert :outer_caught = result
    end

    test "unhandled re-throw produces Throw result" do
      # Handler explicitly re-throws unhandled errors
      handler = fn
        :different -> Comp.pure(:caught)
        other -> Throw.throw(other)
      end

      comp =
        Throw.catch_error(
          Throw.throw(:unhandled),
          handler
        )

      {result, _env} =
        comp
        |> Throw.with_handler()
        |> Comp.run()

      # No match, error propagates as Throw
      assert %Comp.Throw{error: :unhandled} = result
    end

    test "recovery can use effects" do
      comp =
        Throw.catch_error(
          Comp.bind(State.put(10), fn _ -> Throw.throw(:error) end),
          fn _error ->
            Comp.bind(State.get(), fn s -> Comp.pure({:recovered_with_state, s}) end)
          end
        )

      {result, _env} =
        comp
        |> State.with_handler(0)
        |> Throw.with_handler()
        |> Comp.run()

      assert {:recovered_with_state, 10} = result
    end
  end

  describe "try_catch" do
    test "returns Either-style result for success" do
      comp = Throw.try_catch(Comp.pure(42))

      {result, _env} =
        comp
        |> Throw.with_handler()
        |> Comp.run()

      assert {:ok, 42} = result
    end

    test "returns Either-style result for failure" do
      comp = Throw.try_catch(Throw.throw(:failed))

      {result, _env} =
        comp
        |> Throw.with_handler()
        |> Comp.run()

      assert {:error, :failed} = result
    end
  end
end
