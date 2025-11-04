defmodule Freyja.Effects.EffectLogger.ScopedReplayTest do
  use ExUnit.Case

  import Freyja.Con

  alias Freyja.Effects.EffectLogger
  alias Freyja.Effects.Error
  alias Freyja.Effects.List
  alias Freyja.Effects.State
  alias Freyja.Effects.Writer
  alias Freyja.OkResult
  alias Freyja.Run
  alias Freyja.RunOutcome

  describe "simple scoped effect replay - List.fx_map" do
    test "replays simple List.fx_map with no other effects" do
      # Simplest case: just map over a list returning pure values
      computation =
        con [List] do
          result <- fx_map([1, 2, 3], fn x -> return(x * 2) end)
          return(result)
        end

      runner =
        Run.with_handlers(
          l: EffectLogger.Handler,
          list: List.Handler
        )

      first_outcome = computation |> Run.run(runner)

      assert %RunOutcome{
               result: %OkResult{value: [2, 4, 6]},
               outputs: %{l: _log}
             } = first_outcome

      # Replay using rerun
      second_outcome = Run.rerun(computation, first_outcome)

      assert %RunOutcome{
               result: %OkResult{value: [2, 4, 6]},
               outputs: %{l: _replayed_log}
             } = second_outcome

      # IO.puts("\nFirst log:\n#{inspect(log, pretty: true)}")
      # IO.puts("\nReplayed log:\n#{inspect(replayed_log, pretty: true)}")
    end

    test "replays List.fx_map with State inside the map function" do
      # Add State effect inside the mapped function
      map_fn = fn x ->
        con [State] do
          current <- get()
          put(current + x)
          return(x * 2)
        end
      end

      computation =
        con [List, State] do
          result <- fx_map([1, 2, 3], map_fn)
          final_state <- get()
          return({result, final_state})
        end

      runner =
        Run.with_handlers(
          l: EffectLogger.Handler,
          list: List.Handler,
          s: {State.Handler, 0}
        )

      first_outcome = computation |> Run.run(runner)

      assert %RunOutcome{
               result: %OkResult{value: {[2, 4, 6], 6}},
               outputs: %{s: 6, l: _log}
             } = first_outcome

      # Replay
      second_outcome = Run.rerun(computation, first_outcome)

      assert %RunOutcome{
               result: %OkResult{value: {[2, 4, 6], 6}},
               outputs: %{s: 6, l: _replayed_log}
             } = second_outcome

      # IO.puts("\nFirst log:\n#{inspect(log, pretty: true)}")
      # IO.puts("\nReplayed log:\n#{inspect(replayed_log, pretty: true)}")
    end

    test "replays List.fx_map with Writer inside the map function" do
      # Add Writer effect inside the mapped function
      map_fn = fn x ->
        con [Writer] do
          tell({:processing, x})
          return(x + 5)
        end
      end

      computation =
        con [List, Writer] do
          result <- fx_map([10, 20, 30], map_fn)
          return(result)
        end

      runner =
        Run.with_handlers(
          l: EffectLogger.Handler,
          list: List.Handler,
          w: Writer.Handler
        )

      first_outcome = computation |> Run.run(runner)

      assert %RunOutcome{
               result: %OkResult{value: [15, 25, 35]},
               outputs: %{w: [{:processing, 30}, {:processing, 20}, {:processing, 10}], l: _log}
             } = first_outcome

      # Replay
      second_outcome = Run.rerun(computation, first_outcome)

      assert %RunOutcome{
               result: %OkResult{value: [15, 25, 35]},
               outputs: %{
                 w: [{:processing, 30}, {:processing, 20}, {:processing, 10}],
                 l: _replayed_log
               }
             } = second_outcome

      # IO.puts("\nFirst log:\n#{inspect(log, pretty: true)}")
      # IO.puts("\nReplayed log:\n#{inspect(replayed_log, pretty: true)}")
    end
  end

  describe "simple scoped effect replay - Error.catch_fx" do
    test "replays simple catch_fx with successful inner computation" do
      # Simplest case: catch around a successful computation
      computation =
        con [Error] do
          result <-
            catch_fx(
              return(42),
              fn _err -> return(0) end
            )

          return(result)
        end

      runner =
        Run.with_handlers(
          l: EffectLogger.Handler,
          e: Error.Handler
        )

      first_outcome = computation |> Run.run(runner)

      assert %RunOutcome{
               result: %OkResult{value: 42},
               outputs: %{l: _log}
             } = first_outcome

      # Replay
      second_outcome = Run.rerun(computation, first_outcome)

      assert %RunOutcome{
               result: %OkResult{value: 42},
               outputs: %{l: _replayed_log}
             } = second_outcome

      # IO.puts("\nFirst log:\n#{inspect(log, pretty: true)}")
      # IO.puts("\nReplayed log:\n#{inspect(replayed_log, pretty: true)}")
    end

    test "replays catch_fx with error and recovery" do
      # Catch an error and recover
      computation =
        con [Error] do
          result <-
            catch_fx(
              throw_fx(:oops),
              fn err ->
                return({:error, err})
              end
            )

          case result do
            {:ok, val} -> return({:success, val})
            {:error, err} -> return({:recovered, err})
          end
        end

      runner =
        Run.with_handlers(
          l: EffectLogger.Handler,
          e: Error.Handler
        )

      first_outcome = computation |> Run.run(runner)

      assert %RunOutcome{
               result: %OkResult{value: {:recovered, :oops}},
               outputs: %{l: _log}
             } = first_outcome

      # Replay
      second_outcome = Run.rerun(computation, first_outcome)

      assert %RunOutcome{
               result: %OkResult{value: {:recovered, :oops}},
               outputs: %{l: _replayed_log}
             } = second_outcome

      # IO.puts("\nFirst log:\n#{inspect(log, pretty: true)}")
      # IO.puts("\nReplayed log:\n#{inspect(replayed_log, pretty: true)}")
    end

    test "replays catch_fx with State inside" do
      # State effects inside a catch block
      inner_comp =
        con [State] do
          put(10)
          x <- get()
          put(x + 5)
          return({:ok, x})
        end

      computation =
        con [Error, State] do
          result <-
            catch_fx(
              inner_comp,
              fn err -> {:error, err} end
            )

          final_state <- get()

          case result do
            {:ok, val} -> return({:success, val, final_state})
            {:error, err} -> return({:error, err, final_state})
          end
        end

      runner =
        Run.with_handlers(
          l: EffectLogger.Handler,
          e: Error.Handler,
          s: {State.Handler, 0}
        )

      first_outcome = computation |> Run.run(runner)

      assert %RunOutcome{
               result: %OkResult{value: {:success, 10, 15}},
               outputs: %{s: 15, l: _log}
             } = first_outcome

      # Replay
      second_outcome = Run.rerun(computation, first_outcome)

      assert %RunOutcome{
               result: %OkResult{value: {:success, 10, 15}},
               outputs: %{s: 15, l: _replayed_log}
             } = second_outcome

      # IO.puts("\nFirst log:\n#{inspect(log, pretty: true)}")
      # IO.puts("\nReplayed log:\n#{inspect(replayed_log, pretty: true)}")
    end
  end

  describe "complex scoped effect replay" do
    test "replays List.fx_map with mixed State and Writer" do
      # Combine multiple effects in the map function
      map_fn = fn item ->
        con [State, Writer] do
          count <- get()
          put(count + 1)
          tell({:item, item, count})
          return({item, count})
        end
      end

      computation =
        con [List, State, Writer] do
          result <- fx_map([:a, :b, :c], map_fn)
          return(result)
        end

      runner =
        Run.with_handlers(
          l: EffectLogger.Handler,
          list: List.Handler,
          s: {State.Handler, 0},
          w: Writer.Handler
        )

      first_outcome = computation |> Run.run(runner)

      assert %RunOutcome{
               result: %OkResult{value: [{:a, 0}, {:b, 1}, {:c, 2}]},
               outputs: %{
                 s: 3,
                 w: [{:item, :c, 2}, {:item, :b, 1}, {:item, :a, 0}],
                 l: _log
               }
             } = first_outcome

      # Replay
      second_outcome = Run.rerun(computation, first_outcome)

      assert %RunOutcome{
               result: %OkResult{value: [{:a, 0}, {:b, 1}, {:c, 2}]},
               outputs: %{
                 s: 3,
                 w: [{:item, :c, 2}, {:item, :b, 1}, {:item, :a, 0}],
                 l: _replayed_log
               }
             } = second_outcome

      # IO.puts("\nFirst log:\n#{inspect(log, pretty: true)}")
      # IO.puts("\nReplayed log:\n#{inspect(replayed_log, pretty: true)}")
    end

    test "replays nested scoped effects - catch_fx inside List.fx_map" do
      # Nested scoping: error handling inside list iteration
      computation =
        con [List, Error] do
          result <-
            fx_map([1, 0, 3], fn x ->
              catch_fx(
                if x == 0 do
                  throw_fx(:divide_by_zero)
                else
                  return({:ok, 10 / x})
                end,
                fn err -> return({:error, err}) end
              )
            end)

          return(result)
        end

      runner =
        Run.with_handlers(
          l: EffectLogger.Handler,
          list: List.Handler,
          e: Error.Handler
        )

      first_outcome = computation |> Run.run(runner)

      ok_val = 10 / 3

      assert %RunOutcome{
               result: %OkResult{value: [{:ok, 10.0}, {:error, :divide_by_zero}, {:ok, ^ok_val}]},
               outputs: %{l: _log}
             } = first_outcome

      # Replay
      second_outcome = Run.rerun(computation, first_outcome)

      assert %RunOutcome{
               result: %OkResult{value: [{:ok, 10.0}, {:error, :divide_by_zero}, {:ok, ^ok_val}]},
               outputs: %{l: _replayed_log}
             } = second_outcome

      # IO.puts("\nFirst log:\n#{inspect(log, pretty: true)}")
      # IO.puts("\nReplayed log:\n#{inspect(replayed_log, pretty: true)}")
    end

    test "replays List.fx_map inside catch_fx" do
      # Opposite nesting: list iteration inside error handling
      inner_catch =
        con [List] do
          mapped <- fx_map([1, 2, 3], fn x -> return(x * 10) end)
          return({:ok, Enum.sum(mapped)})
        end

      computation =
        con [Error] do
          result <-
            catch_fx(
              inner_catch,
              fn err -> return({:error, err}) end
            )

          case result do
            {:ok, val} -> return({:success, val})
            {:error, err} -> return({:failed, err})
          end
        end

      runner =
        Run.with_handlers(
          l: EffectLogger.Handler,
          e: Error.Handler,
          list: List.Handler
        )

      first_outcome = computation |> Run.run(runner)

      assert %RunOutcome{
               result: %OkResult{value: {:success, 60}},
               outputs: %{l: _log}
             } = first_outcome

      # Replay
      second_outcome = Run.rerun(computation, first_outcome)

      assert %RunOutcome{
               result: %OkResult{value: {:success, 60}},
               outputs: %{l: _replayed_log}
             } = second_outcome

      # IO.puts("\nFirst log:\n#{inspect(log, pretty: true)}")
      # IO.puts("\nReplayed log:\n#{inspect(replayed_log, pretty: true)}")
    end
  end

  describe "scoped effect replay with serialization" do
    test "replays deserialized List.fx_map" do
      # Use strings for JSON compatibility
      computation =
        con [List] do
          result <-
            fx_map(["a", "b", "c"], fn item ->
              con [State] do
                count <- get()
                put(count + 1)
                return(%{item => count})
              end
            end)

          return(result)
        end

      runner =
        Run.with_handlers(
          l: EffectLogger.Handler,
          list: List.Handler,
          s: {State.Handler, 0}
        )

      first_outcome = computation |> Run.run(runner)

      assert %RunOutcome{
               result: %OkResult{value: [%{"a" => 0}, %{"b" => 1}, %{"c" => 2}]},
               outputs: %{l: log, s: 3}
             } = first_outcome

      # IO.puts("\nFirst outcome:\n#{inspect(first_outcome, pretty: true)}")

      # Serialize and deserialize
      json = Jason.encode!(%{l: log, s: 3})
      decoded_map = Jason.decode!(json)

      deserialized_outputs = %{
        l: Freyja.Effects.EffectLogger.Log.from_json(decoded_map["l"]),
        s: decoded_map["s"]
      }

      deserialized_outcome = %{first_outcome | outputs: deserialized_outputs}

      # IO.puts("\nFirst outcome deserialized: :\n#{inspect(deserialized_outcome, pretty: true)}")

      # Replay
      second_outcome = Run.rerun(computation, deserialized_outcome)

      assert %RunOutcome{
               result: %OkResult{value: [%{"a" => 0}, %{"b" => 1}, %{"c" => 2}]},
               outputs: %{s: 3, l: _replayed_log}
             } = second_outcome

      # IO.puts("\nReplayed log:\n#{inspect(replayed_log, pretty: true)}")
    end
  end
end
