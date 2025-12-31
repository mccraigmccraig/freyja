defmodule Skuld.IntegrationTest do
  @moduledoc """
  Integration tests for combined effects.

  Tests interactions between multiple effects to ensure they compose correctly.
  """
  use ExUnit.Case, async: true

  alias Skuld.Comp
  alias Skuld.Env
  alias Skuld.Effects.{Reader, State, Throw, Yield}

  describe "State + Reader" do
    test "effects compose correctly" do
      env =
        Env.new()
        |> State.handler(0)
        |> Reader.handler(10)

      comp =
        Comp.bind(Reader.ask(), fn multiplier ->
          Comp.bind(State.get(), fn current ->
            Comp.bind(State.put(current + multiplier), fn _ ->
              State.get()
            end)
          end)
        end)

      assert {10, _} = Comp.run(comp, env)
    end
  end

  describe "State + Throw" do
    test "state persists through catch" do
      env =
        Env.new()
        |> State.handler(0)
        |> Throw.handler()

      comp =
        Comp.bind(State.put(1), fn _ ->
          Throw.catch_error(
            Comp.bind(State.put(2), fn _ ->
              Comp.bind(Throw.throw(:error), fn _ ->
                # Never reached
                State.put(3)
              end)
            end),
            fn _error -> State.get() end
          )
        end)

      assert {2, final_env} = Comp.run(comp, env)
      assert State.get_state(final_env) == 2
    end
  end

  describe "Yield + State" do
    test "state preserved across suspension" do
      env =
        Env.new()
        |> Yield.handler()
        |> State.handler(0)

      comp =
        Comp.bind(State.put(10), fn _ ->
          Comp.bind(Yield.yield(:suspended), fn input ->
            Comp.bind(State.modify(&(&1 + input)), fn _ ->
              State.get()
            end)
          end)
        end)

      {%Comp.Suspend{value: :suspended, resume: resume}, suspended_env} = Comp.run(comp, env)
      assert State.get_state(suspended_env) == 10

      {15, final_env} = resume.(5)
      assert State.get_state(final_env) == 15
    end
  end

  describe "Yield + Throw (Catch)" do
    test "error after resume is caught" do
      env =
        Env.new()
        |> Yield.handler()
        |> Throw.handler()

      comp =
        Throw.catch_error(
          Comp.bind(Yield.yield(:waiting), fn should_throw ->
            if should_throw do
              Throw.throw(:post_resume_error)
            else
              Comp.pure(:no_error)
            end
          end),
          fn error -> Comp.pure({:caught, error}) end
        )

      {%Comp.Suspend{value: :waiting, resume: resume}, _suspended_env} = Comp.run(comp, env)

      # Resume with false - no error
      assert {{:ok, :no_error}, _} = resume.(false)

      # Resume again with true - error caught
      assert {{:caught, :post_resume_error}, _} = resume.(true)
    end
  end

  describe "Reader.local + Throw" do
    test "local scope restored after throw" do
      env =
        Env.new()
        |> Reader.handler(1)
        |> Throw.handler()

      comp =
        Throw.catch_error(
          Reader.local(
            fn _ -> 100 end,
            Comp.bind(Reader.ask(), fn val ->
              Comp.bind(Throw.throw({:error, val}), fn _ ->
                Comp.pure(:never)
              end)
            end)
          ),
          fn {:error, val} ->
            Comp.bind(Reader.ask(), fn after_val ->
              Comp.pure({:caught, val, after_val})
            end)
          end
        )

      # Error handler sees original reader value (1), not local value (100)
      assert {{:caught, 100, 1}, _} = Comp.run(comp, env)
    end
  end

  describe "Reader.local + Yield" do
    test "local scope preserved across suspension" do
      env =
        Env.new()
        |> Reader.handler(1)
        |> Yield.handler()

      comp =
        Reader.local(
          fn _ -> 100 end,
          Comp.bind(Reader.ask(), fn before ->
            Comp.bind(Yield.yield(:pause), fn _ ->
              Comp.bind(Reader.ask(), fn after_yield ->
                Comp.pure({before, after_yield})
              end)
            end)
          end)
        )

      {%Comp.Suspend{resume: resume}, _} = Comp.run(comp, env)

      # After resume, still inside local scope
      assert {{100, 100}, _} = resume.(:ignored)
    end
  end
end
