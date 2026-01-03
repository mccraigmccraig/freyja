defmodule Skuld.IntegrationTest do
  @moduledoc """
  Integration tests for combined effects.

  Tests interactions between multiple effects to ensure they compose correctly.
  """
  use ExUnit.Case, async: true

  alias Skuld.Comp
  alias Skuld.Effects.Reader
  alias Skuld.Effects.State
  alias Skuld.Effects.Throw
  alias Skuld.Effects.Yield

  describe "State + Reader" do
    test "effects compose correctly" do
      comp =
        Comp.bind(Reader.ask(), fn multiplier ->
          Comp.bind(State.get(), fn current ->
            Comp.bind(State.put(current + multiplier), fn _ ->
              State.get()
            end)
          end)
        end)

      {result, _env} =
        comp
        |> State.with_handler(0)
        |> Reader.with_handler(10)
        |> Comp.run()

      assert result == 10
    end
  end

  describe "State + Throw" do
    test "state persists through catch" do
      # Return both the result and final state value in the computation
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
        |> Comp.bind(fn caught_state ->
          Comp.bind(State.get(), fn final_state ->
            Comp.pure({caught_state, final_state})
          end)
        end)

      {{caught_state, final_state}, _env} =
        comp
        |> State.with_handler(0)
        |> Throw.with_handler()
        |> Comp.run()

      assert caught_state == 2
      assert final_state == 2
    end
  end

  describe "Yield + State" do
    test "state preserved across suspension" do
      # Return both result and state from the computation
      comp =
        Comp.bind(State.put(10), fn _ ->
          Comp.bind(Yield.yield(:suspended), fn input ->
            Comp.bind(State.modify(&(&1 + input)), fn _ ->
              Comp.bind(State.get(), fn final_state ->
                Comp.pure({final_state, final_state})
              end)
            end)
          end)
        end)

      {%Comp.Suspend{value: :suspended, resume: resume}, _suspended_env} =
        comp
        |> Yield.with_handler()
        |> State.with_handler(0)
        |> Comp.run()

      # Note: State is inside the scoped handler, so we check via the result
      # The suspend happens before completion, so state at suspend is 10
      # After resume with 5, state becomes 15
      {{result, final_state}, _final_env} = resume.(5)
      assert result == 15
      assert final_state == 15
    end
  end

  describe "Yield + Throw (Catch)" do
    test "error after resume is caught" do
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

      {%Comp.Suspend{value: :waiting, resume: resume}, _suspended_env} =
        comp
        |> Yield.with_handler()
        |> Throw.with_handler()
        |> Comp.run()

      # Resume with false - no error (no {:ok, ...} wrapper - value passes through unchanged)
      assert {:no_error, _} = resume.(false)

      # Resume again with true - error caught
      assert {{:caught, :post_resume_error}, _} = resume.(true)
    end
  end

  describe "Reader.local + Throw" do
    test "local scope restored after throw" do
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

      {result, _env} =
        comp
        |> Reader.with_handler(1)
        |> Throw.with_handler()
        |> Comp.run()

      # Error handler sees original reader value (1), not local value (100)
      assert {:caught, 100, 1} = result
    end
  end

  describe "Reader.local + Yield" do
    test "local scope preserved across suspension" do
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

      {%Comp.Suspend{resume: resume}, _} =
        comp
        |> Reader.with_handler(1)
        |> Yield.with_handler()
        |> Comp.run()

      # After resume, still inside local scope
      assert {{100, 100}, _} = resume.(:ignored)
    end
  end
end
