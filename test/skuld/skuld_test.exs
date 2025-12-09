defmodule SkuldTest do
  use ExUnit.Case, async: true

  alias Skuld
  alias Skuld.Env
  alias Skuld.Effects.{Reader, State, Throw, Yield}

  describe "pure and bind" do
    test "pure returns value" do
      comp = Skuld.pure(42)
      assert {:done, 42, _env} = Skuld.run(comp, Env.new())
    end

    test "bind sequences computations" do
      comp =
        Skuld.bind(Skuld.pure(1), fn a ->
          Skuld.bind(Skuld.pure(2), fn b ->
            Skuld.pure(a + b)
          end)
        end)

      assert {:done, 3, _env} = Skuld.run(comp, Env.new())
    end

    test "map transforms result" do
      comp = Skuld.map(Skuld.pure(5), &(&1 * 2))
      assert {:done, 10, _env} = Skuld.run(comp, Env.new())
    end

    test "sequence collects results" do
      comps = [Skuld.pure(1), Skuld.pure(2), Skuld.pure(3)]
      comp = Skuld.sequence(comps)
      assert {:done, [1, 2, 3], _env} = Skuld.run(comp, Env.new())
    end
  end

  describe "Reader effect" do
    test "ask reads environment value" do
      env = Env.new() |> Reader.handler(:config_value)

      comp = Reader.ask()
      assert {:done, :config_value, _} = Skuld.run(comp, env)
    end

    test "asks applies function" do
      env = Env.new() |> Reader.handler(%{name: "test", count: 42})

      comp = Reader.asks(& &1.count)
      assert {:done, 42, _} = Skuld.run(comp, env)
    end

    test "local modifies environment for sub-computation" do
      env = Env.new() |> Reader.handler(10)

      comp =
        Skuld.bind(Reader.ask(), fn before ->
          Reader.local(
            &(&1 * 2),
            Skuld.bind(Reader.ask(), fn during ->
              Skuld.bind(Reader.ask(), fn after_local ->
                # after_local is still inside local, so still modified
                Skuld.pure({before, during, after_local})
              end)
            end)
          )
        end)

      # Note: after_local is INSIDE the local, so it sees modified value
      assert {:done, {10, 20, 20}, _} = Skuld.run(comp, env)
    end

    test "local restores environment after" do
      env = Env.new() |> Reader.handler(10)

      inner = Reader.local(&(&1 * 2), Reader.ask())

      comp =
        Skuld.bind(inner, fn _during ->
          # After local completes
          Reader.ask()
        end)

      assert {:done, 10, _} = Skuld.run(comp, env)
    end
  end

  describe "State effect" do
    test "get returns current state" do
      env = Env.new() |> State.handler(42)

      comp = State.get()
      assert {:done, 42, _} = Skuld.run(comp, env)
    end

    test "put updates state" do
      env = Env.new() |> State.handler(0)

      comp =
        Skuld.bind(State.put(100), fn _ ->
          State.get()
        end)

      assert {:done, 100, final_env} = Skuld.run(comp, env)
      assert State.get_state(final_env) == 100
    end

    test "modify transforms state" do
      env = Env.new() |> State.handler(10)

      comp =
        Skuld.bind(State.modify(&(&1 + 5)), fn old ->
          Skuld.bind(State.get(), fn new ->
            Skuld.pure({old, new})
          end)
        end)

      assert {:done, {10, 15}, _} = Skuld.run(comp, env)
    end

    test "state threads through computation" do
      env = Env.new() |> State.handler(0)

      comp =
        Skuld.bind(State.modify(&(&1 + 1)), fn _ ->
          Skuld.bind(State.modify(&(&1 + 1)), fn _ ->
            Skuld.bind(State.modify(&(&1 + 1)), fn _ ->
              State.get()
            end)
          end)
        end)

      assert {:done, 3, _} = Skuld.run(comp, env)
    end
  end

  describe "Throw effect" do
    test "throw produces thrown outcome" do
      env = Env.new() |> Throw.handler()

      comp = Throw.throw(:boom)
      assert {:thrown, :boom, _} = Skuld.run(comp, env)
    end

    test "throw short-circuits computation" do
      env = Env.new() |> Throw.handler() |> State.handler(0)

      comp =
        Skuld.bind(State.put(1), fn _ ->
          Skuld.bind(Throw.throw(:error), fn _ ->
            # Never reached
            State.put(2)
          end)
        end)

      assert {:thrown, :error, final_env} = Skuld.run(comp, env)
      assert State.get_state(final_env) == 1
    end

    test "catch_error catches thrown errors" do
      env = Env.new() |> Throw.handler()

      comp =
        Throw.catch_error(
          Throw.throw(:my_error),
          fn error -> Skuld.pure({:caught, error}) end
        )

      assert {:done, {:caught, :my_error}, _} = Skuld.run(comp, env)
    end

    test "catch_error passes through normal completion" do
      env = Env.new() |> Throw.handler()

      comp =
        Throw.catch_error(
          Skuld.pure(42),
          fn error -> Skuld.pure({:caught, error}) end
        )

      assert {:done, {:ok, 42}, _} = Skuld.run(comp, env)
    end

    test "try_catch returns Either-style result" do
      env = Env.new() |> Throw.handler()

      success_comp = Throw.try_catch(Skuld.pure(42))
      assert {:done, {:ok, 42}, _} = Skuld.run(success_comp, env)

      fail_comp = Throw.try_catch(Throw.throw(:failed))
      assert {:done, {:error, :failed}, _} = Skuld.run(fail_comp, env)
    end

    test "nested catch - inner catches first" do
      env = Env.new() |> Throw.handler()

      comp =
        Throw.catch_error(
          Throw.catch_error(
            Throw.throw(:inner_error),
            fn e -> Skuld.pure({:inner_caught, e}) end
          ),
          fn e -> Skuld.pure({:outer_caught, e}) end
        )

      assert {:done, {:ok, {:inner_caught, :inner_error}}, _} = Skuld.run(comp, env)
    end
  end

  describe "Yield effect" do
    test "yield suspends computation" do
      env = Env.new() |> Yield.handler()

      comp = Yield.yield(:hello)
      assert {:suspended, :hello, resume, _env} = Skuld.run(comp, env)
      assert is_function(resume, 2)
    end

    test "resume continues computation" do
      env = Env.new() |> Yield.handler()

      comp =
        Skuld.bind(Yield.yield(:first), fn x ->
          Skuld.pure({:got, x})
        end)

      {:suspended, :first, resume, suspended_env} = Skuld.run(comp, env)
      assert {:done, {:got, :input_value}, _} = resume.(:input_value, suspended_env)
    end

    test "multiple yields" do
      env = Env.new() |> Yield.handler()

      comp =
        Skuld.bind(Yield.yield(1), fn a ->
          Skuld.bind(Yield.yield(2), fn b ->
            Skuld.bind(Yield.yield(3), fn c ->
              Skuld.pure(a + b + c)
            end)
          end)
        end)

      {:suspended, 1, r1, e1} = Skuld.run(comp, env)
      {:suspended, 2, r2, e2} = r1.(10, e1)
      {:suspended, 3, r3, e3} = r2.(20, e2)
      # 10 + 20 + 30
      {:done, 60, _} = r3.(30, e3)
    end

    test "collect gathers all yields" do
      env = Env.new() |> Yield.handler()

      comp =
        Skuld.bind(Yield.yield(:a), fn _ ->
          Skuld.bind(Yield.yield(:b), fn _ ->
            Skuld.bind(Yield.yield(:c), fn _ ->
              Skuld.pure(:done)
            end)
          end)
        end)

      assert {:done, :done, [:a, :b, :c], _} = Yield.collect(comp, env)
    end

    test "feed provides inputs to yields" do
      env = Env.new() |> Yield.handler()

      comp =
        Skuld.bind(Yield.yield(:want_x), fn x ->
          Skuld.bind(Yield.yield(:want_y), fn y ->
            Skuld.pure(x * y)
          end)
        end)

      assert {:done, 12, [:want_x, :want_y], _} = Yield.feed(comp, env, [3, 4])
    end

    test "feed stops when inputs exhausted" do
      env = Env.new() |> Yield.handler()

      comp =
        Skuld.bind(Yield.yield(1), fn _ ->
          Skuld.bind(Yield.yield(2), fn _ ->
            Skuld.bind(Yield.yield(3), fn _ ->
              Skuld.pure(:done)
            end)
          end)
        end)

      {:suspended, 2, _resume, [1], _env} = Yield.feed(comp, env, [:a])
    end
  end

  describe "combined effects" do
    test "State + Reader" do
      env =
        Env.new()
        |> State.handler(0)
        |> Reader.handler(10)

      comp =
        Skuld.bind(Reader.ask(), fn multiplier ->
          Skuld.bind(State.get(), fn current ->
            Skuld.bind(State.put(current + multiplier), fn _ ->
              State.get()
            end)
          end)
        end)

      assert {:done, 10, _} = Skuld.run(comp, env)
    end

    test "State + Throw" do
      env =
        Env.new()
        |> State.handler(0)
        |> Throw.handler()

      comp =
        Skuld.bind(State.put(1), fn _ ->
          Throw.catch_error(
            Skuld.bind(State.put(2), fn _ ->
              Skuld.bind(Throw.throw(:error), fn _ ->
                # Never reached
                State.put(3)
              end)
            end),
            fn _error -> State.get() end
          )
        end)

      assert {:done, 2, final_env} = Skuld.run(comp, env)
      assert State.get_state(final_env) == 2
    end

    test "Yield + State - state preserved across suspension" do
      env =
        Env.new()
        |> Yield.handler()
        |> State.handler(0)

      comp =
        Skuld.bind(State.put(10), fn _ ->
          Skuld.bind(Yield.yield(:suspended), fn input ->
            Skuld.bind(State.modify(&(&1 + input)), fn _ ->
              State.get()
            end)
          end)
        end)

      {:suspended, :suspended, resume, suspended_env} = Skuld.run(comp, env)
      assert State.get_state(suspended_env) == 10

      {:done, 15, final_env} = resume.(5, suspended_env)
      assert State.get_state(final_env) == 15
    end

    test "Yield inside Catch - error after resume is caught" do
      env =
        Env.new()
        |> Yield.handler()
        |> Throw.handler()

      comp =
        Throw.catch_error(
          Skuld.bind(Yield.yield(:waiting), fn should_throw ->
            if should_throw do
              Throw.throw(:post_resume_error)
            else
              Skuld.pure(:no_error)
            end
          end),
          fn error -> Skuld.pure({:caught, error}) end
        )

      {:suspended, :waiting, resume, suspended_env} = Skuld.run(comp, env)

      # Resume with false - no error
      assert {:done, {:ok, :no_error}, _} = resume.(false, suspended_env)

      # Resume again with true - error caught
      assert {:done, {:caught, :post_resume_error}, _} = resume.(true, suspended_env)
    end
  end
end
