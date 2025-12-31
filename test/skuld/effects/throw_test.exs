defmodule Skuld.Effects.ThrowTest do
  use ExUnit.Case, async: true

  alias Skuld.Comp
  alias Skuld.Env
  alias Skuld.Effects.State
  alias Skuld.Effects.Throw

  describe "throw" do
    test "produces Throw result" do
      env = Env.new() |> Throw.handler()

      comp = Throw.throw(:boom)
      assert {%Comp.Throw{error: :boom}, _} = Comp.run(comp, env)
    end

    test "short-circuits computation" do
      env = Env.new() |> Throw.handler() |> State.handler(0)

      comp =
        Comp.bind(State.put(1), fn _ ->
          Comp.bind(Throw.throw(:error), fn _ ->
            # Never reached
            State.put(2)
          end)
        end)

      assert {%Comp.Throw{error: :error}, final_env} = Comp.run(comp, env)
      assert State.get_state(final_env) == 1
    end
  end

  describe "catch_error" do
    test "catches thrown errors" do
      env = Env.new() |> Throw.handler()

      comp =
        Throw.catch_error(
          Throw.throw(:my_error),
          fn error -> Comp.pure({:caught, error}) end
        )

      assert {{:caught, :my_error}, _} = Comp.run(comp, env)
    end

    test "passes through normal completion unchanged" do
      env = Env.new() |> Throw.handler()

      comp =
        Throw.catch_error(
          Comp.pure(42),
          fn error -> Comp.pure({:caught, error}) end
        )

      # No {:ok, ...} wrapping - value passes through unchanged
      assert {42, _} = Comp.run(comp, env)
    end

    test "recovery continues through normal flow (bind receives value)" do
      env = Env.new() |> Throw.handler()

      inner =
        Throw.catch_error(
          Throw.throw(:error),
          fn _e -> Comp.pure(:recovered) end
        )

      outer =
        Comp.bind(inner, fn result ->
          Comp.pure({:got, result})
        end)

      # Recovery value flows through bind
      assert {{:got, :recovered}, _} = Comp.run(outer, env)
    end

    test "nested catch - inner catches first" do
      env = Env.new() |> Throw.handler()

      comp =
        Throw.catch_error(
          Throw.catch_error(
            Throw.throw(:inner_error),
            fn e -> Comp.pure({:inner_caught, e}) end
          ),
          fn e -> Comp.pure({:outer_caught, e}) end
        )

      # Inner catches, recovery flows through, no wrapping
      assert {{:inner_caught, :inner_error}, _} = Comp.run(comp, env)
    end

    test "re-thrown error propagates to outer catch" do
      env = Env.new() |> Throw.handler()

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

      # Inner doesn't match, re-throws, outer catches
      assert {:outer_caught, _} = Comp.run(comp, env)
    end

    test "unhandled re-throw produces Throw result" do
      env = Env.new() |> Throw.handler()

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

      # No match, error propagates as Throw
      assert {%Comp.Throw{error: :unhandled}, _} = Comp.run(comp, env)
    end

    test "recovery can use effects" do
      env = Env.new() |> Throw.handler() |> State.handler(0)

      comp =
        Throw.catch_error(
          Comp.bind(State.put(10), fn _ -> Throw.throw(:error) end),
          fn _error ->
            Comp.bind(State.get(), fn s -> Comp.pure({:recovered_with_state, s}) end)
          end
        )

      assert {{:recovered_with_state, 10}, _} = Comp.run(comp, env)
    end
  end

  describe "try_catch" do
    test "returns Either-style result for success" do
      env = Env.new() |> Throw.handler()

      comp = Throw.try_catch(Comp.pure(42))
      assert {{:ok, 42}, _} = Comp.run(comp, env)
    end

    test "returns Either-style result for failure" do
      env = Env.new() |> Throw.handler()

      comp = Throw.try_catch(Throw.throw(:failed))
      assert {{:error, :failed}, _} = Comp.run(comp, env)
    end
  end
end
