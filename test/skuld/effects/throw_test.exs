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

    test "passes through normal completion" do
      env = Env.new() |> Throw.handler()

      comp =
        Throw.catch_error(
          Comp.pure(42),
          fn error -> Comp.pure({:caught, error}) end
        )

      assert {{:ok, 42}, _} = Comp.run(comp, env)
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

      assert {{:ok, {:inner_caught, :inner_error}}, _} = Comp.run(comp, env)
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
