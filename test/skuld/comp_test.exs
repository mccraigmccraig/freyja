defmodule Skuld.CompTest do
  use ExUnit.Case, async: true

  alias Skuld.Comp
  alias Skuld.Comp.Env

  describe "pure" do
    test "returns value" do
      comp = Comp.pure(42)
      assert {42, _env} = Comp.run(comp)
    end
  end

  describe "bind" do
    test "sequences computations" do
      comp =
        Comp.bind(Comp.pure(1), fn a ->
          Comp.bind(Comp.pure(2), fn b ->
            Comp.pure(a + b)
          end)
        end)

      assert {3, _env} = Comp.run(comp)
    end
  end

  describe "map" do
    test "transforms result" do
      comp = Comp.map(Comp.pure(5), &(&1 * 2))
      assert {10, _env} = Comp.run(comp)
    end
  end

  describe "sequence" do
    test "collects results" do
      comps = [Comp.pure(1), Comp.pure(2), Comp.pure(3)]
      comp = Comp.sequence(comps)
      assert {[1, 2, 3], _env} = Comp.run(comp)
    end

    test "empty list returns empty list" do
      comp = Comp.sequence([])
      assert {[], _env} = Comp.run(comp)
    end
  end

  describe "traverse" do
    test "maps and sequences" do
      comp = Comp.traverse([1, 2, 3], fn x -> Comp.pure(x * 2) end)
      assert {[2, 4, 6], _env} = Comp.run(comp)
    end
  end

  describe "then_do" do
    test "ignores first result" do
      comp = Comp.then_do(Comp.pure(:ignored), Comp.pure(:kept))
      assert {:kept, _env} = Comp.run(comp)
    end
  end

  describe "flatten" do
    test "flattens nested computation" do
      nested = Comp.pure(Comp.pure(42))
      comp = Comp.flatten(nested)
      assert {42, _env} = Comp.run(comp)
    end
  end

  describe "call/3 validation" do
    alias Comp.InvalidComputation

    test "raises helpful error when given a plain value instead of computation" do
      error =
        assert_raise InvalidComputation, fn ->
          Comp.call(42, Env.new(), fn v, e -> {v, e} end)
        end

      assert error.message =~ "Expected a computation, got: 42"
      assert error.message =~ "Forgot `return(value)` at the end of a comp block"
      assert error.value == 42
    end

    test "raises helpful error when given nil" do
      error =
        assert_raise InvalidComputation, fn ->
          Comp.call(nil, Env.new(), fn v, e -> {v, e} end)
        end

      assert error.message =~ "Expected a computation, got: nil"
      assert error.value == nil
    end

    test "raises helpful error when given a 1-arity function" do
      bad_fn = fn _x -> :oops end

      error =
        assert_raise InvalidComputation, fn ->
          Comp.call(bad_fn, Env.new(), fn v, e -> {v, e} end)
        end

      assert error.message =~ "Expected a computation"
      assert error.message =~ "must be a 2-arity function"
      assert error.value == bad_fn
    end

    test "bind raises when inner computation returns non-computation" do
      # Simulates forgetting return() - the function passed to bind returns a plain value
      comp = Comp.bind(Comp.pure(1), fn _a -> :not_a_computation end)

      error =
        assert_raise InvalidComputation, fn ->
          Comp.run(comp)
        end

      assert error.message =~ "Expected a computation, got: :not_a_computation"
      assert error.message =~ "Forgot `return(value)`"
    end

    test "run raises when given non-computation" do
      error =
        assert_raise InvalidComputation, fn ->
          Comp.run(:not_a_computation)
        end

      assert error.message =~ "Expected a computation, got: :not_a_computation"
    end

    test "flatten raises when inner value is not a computation" do
      # Comp.pure(:not_a_computation) returns a valid computation that yields :not_a_computation
      # flatten then tries to call :not_a_computation as a computation
      nested = Comp.pure(:not_a_computation)
      comp = Comp.flatten(nested)

      error =
        assert_raise InvalidComputation, fn ->
          Comp.run(comp)
        end

      assert error.message =~ "Expected a computation, got: :not_a_computation"
    end
  end

  describe "exception handling" do
    alias Skuld.Comp.Throw, as: ThrowStruct
    alias Skuld.Effects.Throw

    test "raise is converted to Throw with kind: :error" do
      comp = fn _env, _k -> raise "boom" end

      {result, _env} = Comp.run(comp)

      assert %ThrowStruct{error: error} = result
      assert error.kind == :error
      assert %RuntimeError{message: "boom"} = error.payload
      assert is_list(error.stacktrace)
    end

    test "Elixir throw is converted to Throw with kind: :throw" do
      comp = fn _env, _k -> throw(:some_value) end

      {result, _env} = Comp.run(comp)

      assert %ThrowStruct{error: error} = result
      assert error.kind == :throw
      assert error.payload == :some_value
      assert is_list(error.stacktrace)
    end

    test "exit is converted to Throw with kind: :exit" do
      comp = fn _env, _k -> exit(:shutdown) end

      {result, _env} = Comp.run(comp)

      assert %ThrowStruct{error: error} = result
      assert error.kind == :exit
      assert error.payload == :shutdown
      assert is_list(error.stacktrace)
    end

    test "exception in bind is converted to Throw" do
      comp =
        Comp.bind(Comp.pure(1), fn _x ->
          fn _env, _k -> raise "in bind" end
        end)

      {result, _env} = Comp.run(comp)

      assert %ThrowStruct{error: error} = result
      assert error.kind == :error
      assert %RuntimeError{message: "in bind"} = error.payload
    end

    test "exception can be caught with catch_error" do
      comp =
        Throw.catch_error(
          fn _env, _k -> raise "caught me" end,
          fn error ->
            Comp.pure({:caught, error.kind, error.payload.message})
          end
        )
        |> Throw.with_handler()

      {result, _env} = Comp.run(comp)

      assert {:caught, :error, "caught me"} = result
    end

    test "Elixir throw can be caught with catch_error" do
      comp =
        Throw.catch_error(
          fn _env, _k -> throw(:thrown_value) end,
          fn error ->
            Comp.pure({:caught, error.kind, error.payload})
          end
        )
        |> Throw.with_handler()

      {result, _env} = Comp.run(comp)

      assert {:caught, :throw, :thrown_value} = result
    end

    test "nested exceptions - inner caught, outer continues" do
      inner =
        Throw.catch_error(
          fn _env, _k -> raise "inner error" end,
          fn _error -> Comp.pure(:recovered) end
        )

      comp =
        Comp.bind(inner, fn value -> Comp.pure({:continued, value}) end)
        |> Throw.with_handler()

      {result, _env} = Comp.run(comp)

      assert {:continued, :recovered} = result
    end

    test "exception after recovery propagates" do
      comp =
        Throw.catch_error(
          Throw.catch_error(
            fn _env, _k -> raise "first" end,
            fn _error ->
              # Recovery raises another exception
              fn _env, _k -> raise "in recovery" end
            end
          ),
          fn error ->
            Comp.pure({:outer_caught, error.payload.message})
          end
        )
        |> Throw.with_handler()

      {result, _env} = Comp.run(comp)

      assert {:outer_caught, "in recovery"} = result
    end

    test "stacktrace is captured" do
      comp = fn _env, _k ->
        raise "with stacktrace"
      end

      {result, _env} = Comp.run(comp)

      assert %ThrowStruct{error: error} = result
      assert is_list(error.stacktrace)
      assert length(error.stacktrace) > 0
      # Stacktrace entries are tuples {module, function, arity_or_args, location}
      assert Enum.all?(error.stacktrace, &is_tuple/1)
    end

    test "exception in effect handler is converted to Throw" do
      # Create a handler that raises
      raising_handler = fn _args, _env, _k ->
        raise "handler exploded"
      end

      # Use low-level Env.with_handler for testing custom handlers
      comp =
        Comp.effect(:test_effect, :some_args)
        |> Comp.with_handler(:test_effect, raising_handler)
        |> Throw.with_handler()

      {result, _env} = Comp.run(comp)

      assert %ThrowStruct{error: error} = result
      assert error.kind == :error
      assert %RuntimeError{message: "handler exploded"} = error.payload
    end

    test "exception in effect handler can be caught" do
      raising_handler = fn _args, _env, _k ->
        raise "handler error"
      end

      comp =
        Throw.catch_error(
          Comp.effect(:test_effect, :args),
          fn error -> Comp.pure({:caught_handler_error, error.payload.message}) end
        )
        |> Comp.with_handler(:test_effect, raising_handler)
        |> Throw.with_handler()

      {result, _env} = Comp.run(comp)

      assert {:caught_handler_error, "handler error"} = result
    end
  end

  describe "with_handler/3 scoped handlers" do
    alias Skuld.Effects.State

    # Helper to create a state-scoping setup function
    defp state_scope(initial) do
      fn env ->
        previous = Env.get_state(env, State)
        modified = Env.put_state(env, State, initial)
        finally_k = fn value, e -> {value, Env.put_state(e, State, previous)} end
        {modified, finally_k}
      end
    end

    test "installs handler for scope duration" do
      # No handler in outer env

      # Inner comp uses scoped State handler
      inner =
        State.get()
        |> Comp.scoped(state_scope(42))
        |> Comp.with_handler(State, &State.handle/3)

      {result, _env} = Comp.run(inner)

      assert result == 42
    end

    test "handler is removed after scope exits" do
      comp =
        Comp.bind(
          State.get()
          |> Comp.scoped(state_scope(10))
          |> Comp.with_handler(State, &State.handle/3),
          fn inner_result ->
            # After handle scope, State handler should be gone
            # Trying to use State.get() here would fail
            Comp.pure({:inner, inner_result})
          end
        )

      {result, final_env} = Comp.run(comp)

      assert {:inner, 10} = result
      # Handler should be removed
      assert Env.get_handler(final_env, State) == nil
    end

    test "shadows outer handler and restores it" do
      # Use with_handler for outer State
      comp =
        Comp.bind(State.get(), fn outer_before ->
          Comp.bind(
            # Inner scope with its own State, initial 0
            Comp.bind(State.get(), fn inner_val ->
              Comp.bind(State.put(inner_val + 1), fn _ ->
                State.get()
              end)
            end)
            |> Comp.scoped(state_scope(0))
            |> Comp.with_handler(State, &State.handle/3),
            fn inner_result ->
              Comp.bind(State.get(), fn outer_after ->
                Comp.pure({outer_before, inner_result, outer_after})
              end)
            end
          )
        end)
        |> State.with_handler(100)

      {result, _env} = Comp.run(comp)

      # outer_before: 100, inner did 0 -> 1, outer_after: still 100
      assert {100, 1, 100} = result
    end

    test "nested scoped handlers work correctly" do
      comp =
        Comp.bind(State.get(), fn level1 ->
          Comp.bind(
            State.get()
            |> Comp.scoped(state_scope(2))
            |> Comp.with_handler(State, &State.handle/3),
            fn level2 ->
              Comp.bind(State.get(), fn level1_after ->
                Comp.pure({level1, level2, level1_after})
              end)
            end
          )
        end)
        |> Comp.scoped(state_scope(1))
        |> Comp.with_handler(State, &State.handle/3)

      {result, _env} = Comp.run(comp)

      # level1: 1, level2: 2, level1_after: still 1
      assert {1, 2, 1} = result
    end

    test "scoped handler cleanup on throw" do
      alias Skuld.Effects.Throw

      comp =
        Throw.catch_error(
          Comp.bind(State.get(), fn _outer_before ->
            Comp.bind(
              Comp.bind(State.put(42), fn _ ->
                # Throw from inside scoped handler
                Throw.throw(:inner_error)
              end)
              |> Comp.scoped(state_scope(0))
              |> Comp.with_handler(State, &State.handle/3),
              fn _ ->
                # Never reached
                Comp.pure(:unreachable)
              end
            )
          end),
          fn _error ->
            # After throw, outer State should be restored
            Comp.bind(State.get(), fn outer_after ->
              Comp.pure({:caught, outer_after})
            end)
          end
        )
        |> State.with_handler(100)
        |> Throw.with_handler()

      {result, _env} = Comp.run(comp)

      # Outer state (100) should be preserved despite inner throw
      assert {:caught, 100} = result
    end
  end
end
