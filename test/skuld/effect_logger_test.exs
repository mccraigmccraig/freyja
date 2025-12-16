defmodule Skuld.Effects.EffectLoggerTest do
  use ExUnit.Case, async: true

  # Skip until EffectLogger is updated to new {result, env} API
  @moduletag :skip

  alias Skuld
  alias Skuld.Env
  alias Skuld.Effects.{State, Reader, Throw, Yield, EffectLogger}

  describe "logging simple effects" do
    test "logs State.get and State.put" do
      env = Env.new() |> State.handler(0)

      comp =
        Skuld.bind(State.get(), fn x ->
          Skuld.bind(State.put(x + 1), fn _ ->
            Skuld.bind(State.get(), fn y ->
              Skuld.pure(y)
            end)
          end)
        end)

      {outcome, log} = EffectLogger.with_logging(comp, env)

      assert {:done, 1, _env} = outcome
      assert length(log) == 3

      [get1, put1, get2] = log
      assert get1.effect == :state
      assert get1.args == :get
      assert get1.result == 0

      assert put1.effect == :state
      assert put1.args == {:put, 1}
      assert put1.result == :ok

      assert get2.effect == :state
      assert get2.args == :get
      assert get2.result == 1
    end

    test "logs Reader.ask" do
      env = Env.new() |> Reader.handler(%{name: "test"})

      comp = Reader.asks(& &1.name)

      {outcome, log} = EffectLogger.with_logging(comp, env)

      assert {:done, "test", _} = outcome
      assert length(log) == 1

      [ask_entry] = log
      assert ask_entry.effect == :reader
      assert ask_entry.args == :ask
      assert ask_entry.result == %{name: "test"}
    end

    test "logs multiple effects" do
      env =
        Env.new()
        |> State.handler(10)
        |> Reader.handler(:config)

      comp =
        Skuld.bind(Reader.ask(), fn cfg ->
          Skuld.bind(State.get(), fn s ->
            Skuld.bind(State.put(s + 1), fn _ ->
              Skuld.pure({cfg, s})
            end)
          end)
        end)

      {outcome, log} = EffectLogger.with_logging(comp, env)

      assert {:done, {:config, 10}, _} = outcome
      assert length(log) == 3

      effects = Enum.map(log, & &1.effect)
      assert effects == [:reader, :state, :state]
    end

    test "can filter which effects to log" do
      env =
        Env.new()
        |> State.handler(0)
        |> Reader.handler(:config)

      comp =
        Skuld.bind(Reader.ask(), fn _ ->
          Skuld.bind(State.get(), fn x ->
            Skuld.pure(x)
          end)
        end)

      # Only log State, not Reader
      {outcome, log} = EffectLogger.with_logging(comp, env, effects: [:state])

      assert {:done, 0, _} = outcome
      assert length(log) == 1
      assert hd(log).effect == :state
    end
  end

  describe "logging control effects" do
    test "logs Throw" do
      env = Env.new() |> Throw.handler()

      comp = Throw.throw(:my_error)

      {outcome, log} = EffectLogger.with_logging(comp, env)

      assert {:thrown, :my_error, _} = outcome
      assert length(log) == 1

      [throw_entry] = log
      assert throw_entry.effect == :throw
      assert throw_entry.args == {:throw, :my_error}
      assert throw_entry.error == :my_error
    end

    test "logs effects before throw" do
      env =
        Env.new()
        |> State.handler(0)
        |> Throw.handler()

      comp =
        Skuld.bind(State.put(42), fn _ ->
          Skuld.bind(State.get(), fn x ->
            Skuld.bind(Throw.throw({:error, x}), fn _ ->
              # Never reached
              State.put(999)
            end)
          end)
        end)

      {outcome, log} = EffectLogger.with_logging(comp, env)

      assert {:thrown, {:error, 42}, _} = outcome
      assert length(log) == 3

      effects = Enum.map(log, & &1.effect)
      assert effects == [:state, :state, :throw]
    end
  end

  describe "replay simple effects" do
    test "replays State effects from log" do
      env = Env.new() |> State.handler(0)

      comp =
        Skuld.bind(State.get(), fn x ->
          Skuld.bind(State.put(x + 1), fn _ ->
            Skuld.bind(State.get(), fn y ->
              Skuld.pure({x, y})
            end)
          end)
        end)

      # First run - capture log
      {outcome1, log} = EffectLogger.with_logging(comp, env)
      assert {:done, {0, 1}, _} = outcome1

      # Replay - should get same result without real State operations
      # Use a fresh env with different initial state to prove replay works
      replay_env = Env.new() |> State.handler(999)
      outcome2 = EffectLogger.replay(comp, replay_env, log)

      # Result should match original, not the 999 initial state
      assert {:done, {0, 1}, _} = outcome2
    end

    test "replays Reader effects from log" do
      env = Env.new() |> Reader.handler(%{value: 42})

      comp = Reader.asks(& &1.value)

      {outcome1, log} = EffectLogger.with_logging(comp, env)
      assert {:done, 42, _} = outcome1

      # Replay with different reader value
      replay_env = Env.new() |> Reader.handler(%{value: 999})
      outcome2 = EffectLogger.replay(comp, replay_env, log)

      # Should get original logged value
      assert {:done, 42, _} = outcome2
    end

    test "replay detects divergence" do
      env = Env.new() |> State.handler(0)

      comp1 =
        Skuld.bind(State.get(), fn _ ->
          Skuld.pure(:done)
        end)

      {_outcome, log} = EffectLogger.with_logging(comp1, env)

      # Different computation that does State.put instead of State.get
      comp2 =
        Skuld.bind(State.put(42), fn _ ->
          Skuld.pure(:done)
        end)

      assert_raise RuntimeError, ~r/Replay divergence/, fn ->
        EffectLogger.replay(comp2, env, log)
      end
    end

    test "replay with :execute falls through on missing" do
      env = Env.new() |> State.handler(0)

      comp1 = State.get()
      {_outcome, log} = EffectLogger.with_logging(comp1, env)

      # Computation with extra effect not in log
      comp2 =
        Skuld.bind(State.get(), fn x ->
          Skuld.bind(State.put(x + 100), fn _ ->
            State.get()
          end)
        end)

      # With :execute, extra effects run normally
      outcome = EffectLogger.replay(comp2, env, log, on_missing: :execute)
      assert {:done, 100, _} = outcome
    end
  end

  describe "logging and replay round-trip" do
    test "complex computation round-trips correctly" do
      env =
        Env.new()
        |> State.handler(0)
        |> Reader.handler(%{multiplier: 10})

      comp =
        Skuld.bind(Reader.ask(), fn %{multiplier: mult} ->
          Skuld.bind(State.get(), fn x ->
            Skuld.bind(State.put(x + 1), fn _ ->
              Skuld.bind(State.get(), fn y ->
                Skuld.bind(State.put(y * mult), fn _ ->
                  Skuld.bind(State.get(), fn final ->
                    Skuld.pure({x, y, final})
                  end)
                end)
              end)
            end)
          end)
        end)

      # Original run
      {outcome1, log} = EffectLogger.with_logging(comp, env)
      assert {:done, {0, 1, 10}, _} = outcome1

      # Replay with completely different initial state
      replay_env =
        Env.new()
        |> State.handler(999)
        |> Reader.handler(%{multiplier: 1})

      outcome2 = EffectLogger.replay(comp, replay_env, log)
      assert {:done, {0, 1, 10}, _} = outcome2
    end
  end

  describe "log format" do
    test "log entries have expected fields" do
      env = Env.new() |> State.handler(42)

      comp = State.get()

      {_outcome, [entry]} = EffectLogger.with_logging(comp, env)

      assert Map.has_key?(entry, :id)
      assert Map.has_key?(entry, :effect)
      assert Map.has_key?(entry, :args)
      assert Map.has_key?(entry, :result)
      assert Map.has_key?(entry, :timestamp)
    end

    test "custom timestamp function" do
      env = Env.new() |> State.handler(0)
      comp = State.get()

      fixed_time = ~U[2024-01-01 12:00:00Z]

      {_outcome, [entry]} =
        EffectLogger.with_logging(comp, env, timestamp_fn: fn -> fixed_time end)

      assert entry.timestamp == fixed_time
    end

    test "custom id function" do
      env = Env.new() |> State.handler(0)
      comp = State.get()

      {_outcome, [entry]} = EffectLogger.with_logging(comp, env, id_fn: fn -> "custom-id" end)

      assert entry.id == "custom-id"
    end
  end
end
