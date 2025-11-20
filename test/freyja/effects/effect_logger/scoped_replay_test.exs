defmodule Freyja.Effects.EffectLogger.ScopedReplayTest do
  use ExUnit.Case

  use Freyja.Syntax

  alias Freyja.Effects.EffectLogger
  alias Freyja.Effects.State
  alias Freyja.Effects.Writer
  alias Freyja.Hefty
  alias Freyja.Run
  alias Freyja.Effects.{Lift, Throw}
  alias Freyja.Effects.{Catch, FxList}
  alias Freyja.Effects.Throw.Handler, as: ThrowHandler
  alias Freyja.RunOutcome

  describe "simple scoped effect replay - FxList.fx_map" do
    test "replays simple FxList.fx_map with no other effects" do
      # Simplest case: just map over a list returning pure values
      # Using Hefty - let's see if EffectLogger logs the elaborated operations!
      computation =
        hefty do
          result <- FxList.fx_map([1, 2, 3], fn x -> return(x * 2) end)
          return(result)
        end

      algebras = [Lift.Algebra, FxList.Algebra]
      handlers = [EffectLogger.Handler]
      initial_states = %{}

      first_outcome = Run.run(computation, algebras, handlers, initial_states)

      assert %RunOutcome{
               result: [2, 4, 6],
               outputs: outputs
             } = first_outcome

      # Check that EffectLogger logged something
      assert Map.has_key?(outputs, EffectLogger.Handler)

      # Replay - re-elaborate and re-run with outputs as initial states
      # The log should contain the ELABORATED first-order operations
      second_outcome = Run.run(computation, algebras, handlers, outputs)

      assert %RunOutcome{
               result: [2, 4, 6],
               outputs: replayed_outputs
             } = second_outcome

      assert Map.has_key?(replayed_outputs, EffectLogger.Handler)

      # IO.puts("\nFirst log:\n#{inspect(log, pretty: true)}")
      # IO.puts("\nReplayed log:\n#{inspect(replayed_log, pretty: true)}")
    end

    test "replays List.fx_map with State inside the map function" do
      # Add State effect inside the mapped function
      map_fn = fn x ->
        hefty do
          current <- Lift.lift(State.get())
          _ <- Lift.lift(State.put(current + x))
          return(x * 2)
        end
      end

      computation =
        hefty do
          result <- FxList.fx_map([1, 2, 3], map_fn)
          final_state <- Lift.lift(State.get())
          return({result, final_state})
        end

      algebras = [Lift.Algebra, FxList.Algebra]
      handlers = [EffectLogger.Handler, State.Handler]
      initial_states = %{State.Handler => 0}

      first_outcome = Run.run(computation, algebras, handlers, initial_states)

      assert %RunOutcome{
               result: {[2, 4, 6], 6},
               outputs: outputs
             } = first_outcome

      assert Map.get(outputs, State.Handler) == 6
      assert Map.has_key?(outputs, EffectLogger.Handler)

      # Replay - re-elaborate and re-run with outputs as initial states
      second_outcome = Run.run(computation, algebras, handlers, outputs)

      assert %RunOutcome{
               result: {[2, 4, 6], 6},
               outputs: replayed_outputs
             } = second_outcome

      assert Map.get(replayed_outputs, State.Handler) == 6
      assert Map.has_key?(replayed_outputs, EffectLogger.Handler)

      # IO.puts("\nFirst log:\n#{inspect(log, pretty: true)}")
      # IO.puts("\nReplayed log:\n#{inspect(replayed_log, pretty: true)}")
    end

    test "replays List.fx_map with Writer inside the map function" do
      # Add Writer effect inside the mapped function
      map_fn = fn x ->
        hefty do
          _ <- Lift.lift(Writer.tell({:processing, x}))
          return(x + 5)
        end
      end

      computation =
        hefty do
          result <- FxList.fx_map([10, 20, 30], map_fn)
          return(result)
        end

      algebras = [Lift.Algebra, FxList.Algebra]
      handlers = [EffectLogger.Handler, Writer.Handler]
      initial_states = %{}

      first_outcome = Run.run(computation, algebras, handlers, initial_states)

      assert %RunOutcome{
               result: [15, 25, 35],
               outputs: outputs
             } = first_outcome

      assert Map.get(outputs, Writer.Handler) == [
               {:processing, 30},
               {:processing, 20},
               {:processing, 10}
             ]

      assert Map.has_key?(outputs, EffectLogger.Handler)

      # Replay - re-elaborate and re-run with outputs as initial states
      second_outcome = Run.run(computation, algebras, handlers, outputs)

      assert %RunOutcome{
               result: [15, 25, 35],
               outputs: replayed_outputs
             } = second_outcome

      assert Map.get(replayed_outputs, Writer.Handler) == [
               {:processing, 30},
               {:processing, 20},
               {:processing, 10}
             ]

      assert Map.has_key?(replayed_outputs, EffectLogger.Handler)

      # IO.puts("\nFirst log:\n#{inspect(log, pretty: true)}")
      # IO.puts("\nReplayed log:\n#{inspect(replayed_log, pretty: true)}")
    end
  end

  describe "simple scoped effect replay - Catch.catch_hefty" do
    test "replays simple catch_hefty with successful inner computation" do
      # Simplest case: catch around a successful computation
      computation =
        hefty do
          result <-
            Catch.catch_hefty(
              Hefty.pure(42),
              fn _err -> Hefty.pure(0) end
            )

          return(result)
        end

      algebras = [Catch.Algebra, Lift.Algebra]
      handlers = [EffectLogger.Handler, ThrowHandler]
      initial_states = %{}

      first_outcome = Run.run(computation, algebras, handlers, initial_states)

      assert %RunOutcome{
               result: {:ok, 42},
               outputs: outputs
             } = first_outcome

      assert Map.has_key?(outputs, EffectLogger.Handler)

      # Replay - re-elaborate and re-run with outputs as initial states
      second_outcome = Run.run(computation, algebras, handlers, outputs)

      assert %RunOutcome{
               result: {:ok, 42},
               outputs: replayed_outputs
             } = second_outcome

      assert Map.has_key?(replayed_outputs, EffectLogger.Handler)

      # IO.puts("\nFirst log:\n#{inspect(log, pretty: true)}")
      # IO.puts("\nReplayed log:\n#{inspect(replayed_log, pretty: true)}")
    end

    test "replays catch_hefty with error and recovery" do
      # Catch an error and recover
      computation =
        hefty do
          result <-
            Catch.catch_hefty(
              Lift.lift(Throw.throw_error(:oops)),
              fn _err -> Hefty.pure({:error, :oops}) end
            )

          case result do
            {:ok, val} -> return({:success, val})
            {:error, err} -> return({:recovered, err})
          end
        end

      algebras = [Catch.Algebra, Lift.Algebra]
      handlers = [EffectLogger.Handler, ThrowHandler]
      initial_states = %{}

      first_outcome = Run.run(computation, algebras, handlers, initial_states)

      assert %RunOutcome{
               result: {:ok, {:recovered, :oops}},
               outputs: outputs
             } = first_outcome

      assert Map.has_key?(outputs, EffectLogger.Handler)

      # Replay - re-elaborate and re-run with outputs as initial states
      second_outcome = Run.run(computation, algebras, handlers, outputs)

      assert %RunOutcome{
               result: {:ok, {:recovered, :oops}},
               outputs: replayed_outputs
             } = second_outcome

      assert Map.has_key?(replayed_outputs, EffectLogger.Handler)

      # IO.puts("\nFirst log:\n#{inspect(log, pretty: true)}")
      # IO.puts("\nReplayed log:\n#{inspect(replayed_log, pretty: true)}")
    end

    test "replays catch_hefty with State inside" do
      # State effects inside a catch block
      inner_comp =
        hefty do
          _ <- Lift.lift(State.put(10))
          x <- Lift.lift(State.get())
          _ <- Lift.lift(State.put(x + 5))
          return({:ok, x})
        end

      computation =
        hefty do
          result <-
            Catch.catch_hefty(
              inner_comp,
              fn _err -> Hefty.pure({:error, :caught}) end
            )

          final_state <- Lift.lift(State.get())

          case result do
            {:ok, val} -> return({:success, val, final_state})
            {:error, err} -> return({:error, err, final_state})
          end
        end

      algebras = [Catch.Algebra, Lift.Algebra]
      handlers = [EffectLogger.Handler, ThrowHandler, State.Handler]
      initial_states = %{State.Handler => 0}

      first_outcome = Run.run(computation, algebras, handlers, initial_states)

      assert %RunOutcome{
               result: {:success, 10, 15},
               outputs: outputs
             } = first_outcome

      assert Map.get(outputs, State.Handler) == 15
      assert Map.has_key?(outputs, EffectLogger.Handler)

      # Replay - re-elaborate and re-run with outputs as initial states
      second_outcome = Run.run(computation, algebras, handlers, outputs)

      assert %RunOutcome{
               result: {:success, 10, 15},
               outputs: replayed_outputs
             } = second_outcome

      assert Map.get(replayed_outputs, State.Handler) == 15
      assert Map.has_key?(replayed_outputs, EffectLogger.Handler)

      # IO.puts("\nFirst log:\n#{inspect(log, pretty: true)}")
      # IO.puts("\nReplayed log:\n#{inspect(replayed_log, pretty: true)}")
    end
  end

  describe "complex scoped effect replay" do
    test "replays List.fx_map with mixed State and Writer" do
      # Combine multiple effects in the map function
      map_fn = fn item ->
        hefty do
          count <- Lift.lift(State.get())
          _ <- Lift.lift(State.put(count + 1))
          _ <- Lift.lift(Writer.tell({:item, item, count}))
          return({item, count})
        end
      end

      computation =
        hefty do
          result <- FxList.fx_map([:a, :b, :c], map_fn)
          return(result)
        end

      algebras = [Lift.Algebra, FxList.Algebra]
      handlers = [EffectLogger.Handler, State.Handler, Writer.Handler]
      initial_states = %{State.Handler => 0}

      first_outcome = Run.run(computation, algebras, handlers, initial_states)

      assert %RunOutcome{
               result: [{:a, 0}, {:b, 1}, {:c, 2}],
               outputs: outputs
             } = first_outcome

      assert Map.get(outputs, State.Handler) == 3
      assert Map.get(outputs, Writer.Handler) == [{:item, :c, 2}, {:item, :b, 1}, {:item, :a, 0}]
      assert Map.has_key?(outputs, EffectLogger.Handler)

      # Replay - re-elaborate and re-run with outputs as initial states
      second_outcome = Run.run(computation, algebras, handlers, outputs)

      assert %RunOutcome{
               result: [{:a, 0}, {:b, 1}, {:c, 2}],
               outputs: replayed_outputs
             } = second_outcome

      assert Map.get(replayed_outputs, State.Handler) == 3

      assert Map.get(replayed_outputs, Writer.Handler) == [
               {:item, :c, 2},
               {:item, :b, 1},
               {:item, :a, 0}
             ]

      assert Map.has_key?(replayed_outputs, EffectLogger.Handler)

      # IO.puts("\nFirst log:\n#{inspect(log, pretty: true)}")
      # IO.puts("\nReplayed log:\n#{inspect(replayed_log, pretty: true)}")
    end

    test "replays nested scoped effects - catch_hefty inside List.fx_map" do
      # Nested scoping: error handling inside list iteration
      computation =
        hefty do
          result <-
            FxList.fx_map([1, 0, 3], fn x ->
              Catch.catch_hefty(
                if x == 0 do
                  Lift.lift(Throw.throw_error(:divide_by_zero))
                else
                  Hefty.pure({:ok, 10 / x})
                end,
                fn _err -> Hefty.pure({:error, :divide_by_zero}) end
              )
            end)

          return(result)
        end

      algebras = [Catch.Algebra, Lift.Algebra, FxList.Algebra]
      handlers = [EffectLogger.Handler, ThrowHandler]
      initial_states = %{}

      first_outcome = Run.run(computation, algebras, handlers, initial_states)

      ok_val = 10 / 3

      assert %RunOutcome{
               result: {:ok, [{:ok, 10.0}, {:error, :divide_by_zero}, {:ok, ^ok_val}]},
               outputs: outputs
             } = first_outcome

      assert Map.has_key?(outputs, EffectLogger.Handler)

      # Replay - re-elaborate and re-run with outputs as initial states
      second_outcome = Run.run(computation, algebras, handlers, outputs)

      assert %RunOutcome{
               result: {:ok, [{:ok, 10.0}, {:error, :divide_by_zero}, {:ok, ^ok_val}]},
               outputs: replayed_outputs
             } = second_outcome

      assert Map.has_key?(replayed_outputs, EffectLogger.Handler)

      # IO.puts("\nFirst log:\n#{inspect(log, pretty: true)}")
      # IO.puts("\nReplayed log:\n#{inspect(replayed_log, pretty: true)}")
    end

    test "replays List.fx_map inside catch_hefty" do
      # Opposite nesting: list iteration inside error handling
      inner_catch =
        hefty do
          mapped <- FxList.fx_map([1, 2, 3], fn x -> Hefty.pure(x * 10) end)
          return({:ok, Enum.sum(mapped)})
        end

      computation =
        hefty do
          result <-
            Catch.catch_hefty(
              inner_catch,
              fn _err -> Hefty.pure({:error, :caught}) end
            )

          case result do
            {:ok, val} -> return({:success, val})
            {:error, err} -> return({:failed, err})
          end
        end

      algebras = [Catch.Algebra, Lift.Algebra, FxList.Algebra]
      handlers = [EffectLogger.Handler, ThrowHandler]
      initial_states = %{}

      first_outcome = Run.run(computation, algebras, handlers, initial_states)

      assert %RunOutcome{
               result: {:ok, {:success, 60}},
               outputs: outputs
             } = first_outcome

      assert Map.has_key?(outputs, EffectLogger.Handler)

      # Replay - re-elaborate and re-run with outputs as initial states
      second_outcome = Run.run(computation, algebras, handlers, outputs)

      assert %RunOutcome{
               result: {:ok, {:success, 60}},
               outputs: replayed_outputs
             } = second_outcome

      assert Map.has_key?(replayed_outputs, EffectLogger.Handler)

      # IO.puts("\nFirst log:\n#{inspect(log, pretty: true)}")
      # IO.puts("\nReplayed log:\n#{inspect(replayed_log, pretty: true)}")
    end
  end

  describe "scoped effect replay with serialization" do
    test "replays deserialized List.fx_map" do
      # Use strings for JSON compatibility
      computation =
        hefty do
          result <-
            FxList.fx_map(["a", "b", "c"], fn item ->
              hefty do
                count <- Lift.lift(State.get())
                _ <- Lift.lift(State.put(count + 1))
                return(%{item => count})
              end
            end)

          return(result)
        end

      algebras = [Lift.Algebra, FxList.Algebra]
      handlers = [EffectLogger.Handler, State.Handler]
      initial_states = %{State.Handler => 0}

      first_outcome = Run.run(computation, algebras, handlers, initial_states)

      assert %RunOutcome{
               result: [%{"a" => 0}, %{"b" => 1}, %{"c" => 2}],
               outputs: outputs
             } = first_outcome

      log = Map.get(outputs, EffectLogger.Handler)
      state = Map.get(outputs, State.Handler)
      assert state == 3

      # IO.puts("\nFirst outcome:\n#{inspect(first_outcome, pretty: true)}")

      # Serialize and deserialize
      json = Jason.encode!(%{l: log, s: state})
      decoded_map = Jason.decode!(json)

      deserialized_outputs = %{
        EffectLogger.Handler => Freyja.Effects.EffectLogger.Log.from_json(decoded_map["l"]),
        State.Handler => decoded_map["s"]
      }

      # IO.puts("\nFirst outcome deserialized: :\n#{inspect(first_outcome, pretty: true)}")

      # Replay - re-elaborate and re-run with deserialized outputs as initial states
      second_outcome = Run.run(computation, algebras, handlers, deserialized_outputs)

      assert %RunOutcome{
               result: [%{"a" => 0}, %{"b" => 1}, %{"c" => 2}],
               outputs: replayed_outputs
             } = second_outcome

      assert Map.get(replayed_outputs, State.Handler) == 3
      assert Map.has_key?(replayed_outputs, EffectLogger.Handler)

      # IO.puts("\nReplayed log:\n#{inspect(replayed_log, pretty: true)}")
    end
  end
end
