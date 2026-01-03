defmodule Skuld.Effects.EffectLoggerTest do
  use ExUnit.Case, async: true

  alias Skuld.Comp
  alias Skuld.Effects.EffectLogger
  alias Skuld.Effects.EffectLogger.LogEntry.Completed
  alias Skuld.Effects.EffectLogger.LogEntry.Thrown
  alias Skuld.Effects.Reader
  alias Skuld.Effects.State
  alias Skuld.Effects.Throw

  describe "logging simple effects" do
    test "logs State.get and State.put" do
      comp =
        Comp.bind(State.get(), fn x ->
          Comp.bind(State.put(x + 1), fn _ ->
            Comp.bind(State.get(), fn y ->
              Comp.pure(y)
            end)
          end)
        end)

      {{result, log}, _env} =
        comp
        |> EffectLogger.with_logging()
        |> State.with_handler(0)
        |> Comp.run()

      assert result == 1
      assert length(log) == 3

      [get1, put1, get2] = log
      assert %Completed{effect: State, args: %State.Get{}, result: 0} = get1
      assert %Completed{effect: State, args: %State.Put{value: 1}, result: :ok} = put1
      assert %Completed{effect: State, args: %State.Get{}, result: 1} = get2
    end

    test "logs Reader.ask" do
      comp = Reader.asks(& &1.name)

      {{result, log}, _env} =
        comp
        |> EffectLogger.with_logging()
        |> Reader.with_handler(%{name: "test"})
        |> Comp.run()

      assert result == "test"
      assert length(log) == 1

      [ask_entry] = log
      assert %Completed{effect: Reader, args: %Reader.Ask{}, result: %{name: "test"}} = ask_entry
    end

    test "logs multiple effects" do
      comp =
        Comp.bind(Reader.ask(), fn cfg ->
          Comp.bind(State.get(), fn s ->
            Comp.bind(State.put(s + 1), fn _ ->
              Comp.pure({cfg, s})
            end)
          end)
        end)

      {{result, log}, _env} =
        comp
        |> EffectLogger.with_logging()
        |> State.with_handler(10)
        |> Reader.with_handler(:config)
        |> Comp.run()

      assert result == {:config, 10}
      assert length(log) == 3

      effects = Enum.map(log, & &1.effect)
      assert effects == [Reader, State, State]
    end

    test "can filter which effects to log" do
      comp =
        Comp.bind(Reader.ask(), fn _ ->
          Comp.bind(State.get(), fn x ->
            Comp.pure(x)
          end)
        end)

      # Only log State, not Reader
      {{result, log}, _env} =
        comp
        |> EffectLogger.with_logging(effects: [State])
        |> State.with_handler(0)
        |> Reader.with_handler(:config)
        |> Comp.run()

      assert result == 0
      assert length(log) == 1
      assert hd(log).effect == State
    end
  end

  describe "logging control effects" do
    test "logs Throw" do
      comp = Throw.throw(:my_error)

      {{result, log}, _env} =
        comp
        |> EffectLogger.with_logging()
        |> Throw.with_handler()
        |> Comp.run()

      assert %Comp.Throw{error: :my_error} = result
      assert length(log) == 1

      [throw_entry] = log

      assert %Thrown{
               effect: Throw,
               args: %Throw.ThrowOp{error: :my_error},
               error: :my_error
             } = throw_entry
    end

    test "logs effects before throw" do
      comp =
        Comp.bind(State.put(42), fn _ ->
          Comp.bind(State.get(), fn x ->
            Comp.bind(Throw.throw({:error, x}), fn _ ->
              # Never reached
              State.put(999)
            end)
          end)
        end)

      {{result, log}, _env} =
        comp
        |> EffectLogger.with_logging()
        |> State.with_handler(0)
        |> Throw.with_handler()
        |> Comp.run()

      assert %Comp.Throw{error: {:error, 42}} = result
      assert length(log) == 3

      effects = Enum.map(log, & &1.effect)
      assert effects == [State, State, Throw]
    end
  end

  describe "replay simple effects" do
    test "replays State effects from log" do
      comp =
        Comp.bind(State.get(), fn x ->
          Comp.bind(State.put(x + 1), fn _ ->
            Comp.bind(State.get(), fn y ->
              Comp.pure({x, y})
            end)
          end)
        end)

      # First run - capture log
      {{result1, log}, _env} =
        comp
        |> EffectLogger.with_logging()
        |> State.with_handler(0)
        |> Comp.run()

      assert result1 == {0, 1}

      # Replay - should get same result without real State operations
      # Use different initial state to prove replay works
      {result2, _env} =
        comp
        |> EffectLogger.replay(log)
        |> State.with_handler(999)
        |> Comp.run()

      # Result should match original, not the 999 initial state
      assert result2 == {0, 1}
    end

    test "replays Reader effects from log" do
      comp = Reader.asks(& &1.value)

      # First run - capture log
      {{result1, log}, _env} =
        comp
        |> EffectLogger.with_logging()
        |> Reader.with_handler(%{value: 42})
        |> Comp.run()

      assert result1 == 42

      # Replay with different reader value
      {result2, _env} =
        comp
        |> EffectLogger.replay(log)
        |> Reader.with_handler(%{value: 999})
        |> Comp.run()

      # Should get original logged value
      assert result2 == 42
    end

    test "replay detects divergence" do
      comp1 =
        Comp.bind(State.get(), fn _ ->
          Comp.pure(:done)
        end)

      {{_result, log}, _env} =
        comp1
        |> EffectLogger.with_logging()
        |> State.with_handler(0)
        |> Comp.run()

      # Different computation that does State.put instead of State.get
      comp2 =
        Comp.bind(State.put(42), fn _ ->
          Comp.pure(:done)
        end)

      # Divergence raises RuntimeError which is converted to a Throw
      {result, _env} =
        comp2
        |> EffectLogger.replay(log)
        |> State.with_handler(0)
        |> Throw.with_handler()
        |> Comp.run()

      assert %Comp.Throw{error: error} = result
      assert error.kind == :error
      assert %RuntimeError{message: msg} = error.payload
      assert msg =~ "Replay divergence"
    end

    test "replay with :execute falls through on missing" do
      comp1 = State.get()

      {{_result, log}, _env} =
        comp1
        |> EffectLogger.with_logging()
        |> State.with_handler(0)
        |> Comp.run()

      # Computation with extra effect not in log
      comp2 =
        Comp.bind(State.get(), fn x ->
          Comp.bind(State.put(x + 100), fn _ ->
            State.get()
          end)
        end)

      # With :execute, extra effects run normally
      {result, _env} =
        comp2
        |> EffectLogger.replay(log, on_missing: :execute)
        |> State.with_handler(0)
        |> Comp.run()

      assert result == 100
    end
  end

  describe "logging and replay round-trip" do
    test "complex computation round-trips correctly" do
      comp =
        Comp.bind(Reader.ask(), fn %{multiplier: mult} ->
          Comp.bind(State.get(), fn x ->
            Comp.bind(State.put(x + 1), fn _ ->
              Comp.bind(State.get(), fn y ->
                Comp.bind(State.put(y * mult), fn _ ->
                  Comp.bind(State.get(), fn final ->
                    Comp.pure({x, y, final})
                  end)
                end)
              end)
            end)
          end)
        end)

      # Original run
      {{result1, log}, _env} =
        comp
        |> EffectLogger.with_logging()
        |> State.with_handler(0)
        |> Reader.with_handler(%{multiplier: 10})
        |> Comp.run()

      assert result1 == {0, 1, 10}

      # Replay with completely different initial state
      {result2, _env} =
        comp
        |> EffectLogger.replay(log)
        |> State.with_handler(999)
        |> Reader.with_handler(%{multiplier: 1})
        |> Comp.run()

      assert result2 == {0, 1, 10}
    end
  end

  describe "log format" do
    test "log entries are Completed structs with expected fields" do
      comp = State.get()

      {{_result, [entry]}, _env} =
        comp
        |> EffectLogger.with_logging()
        |> State.with_handler(42)
        |> Comp.run()

      assert %Completed{
               id: id,
               effect: State,
               args: %State.Get{},
               result: 42,
               timestamp: timestamp
             } = entry

      assert id != nil
      assert %DateTime{} = timestamp
    end

    test "custom timestamp function" do
      comp = State.get()
      fixed_time = ~U[2024-01-01 12:00:00Z]

      {{_result, [entry]}, _env} =
        comp
        |> EffectLogger.with_logging(timestamp_fn: fn -> fixed_time end)
        |> State.with_handler(0)
        |> Comp.run()

      assert entry.timestamp == fixed_time
    end

    test "custom id function" do
      comp = State.get()

      {{_result, [entry]}, _env} =
        comp
        |> EffectLogger.with_logging(id_fn: fn -> "custom-id" end)
        |> State.with_handler(0)
        |> Comp.run()

      assert entry.id == "custom-id"
    end
  end
end
