defmodule Freyja.Effects.EffectLogger.UnscopedReplayTest do
  use ExUnit.Case

  import Freyja.Con

  alias Freyja.Effects.EffectLogger
  alias Freyja.Effects.State
  alias Freyja.Effects.Writer
  alias Freyja.Run
  alias Freyja.RunOutcome

  describe "unscoped effect replay without serialization" do
    test "replays State effects from log" do
      # Define a computation with State effects
      computation =
        con [State] do
          _ <- put(:initial_value)
          a <- get()
          _ <- put(:updated_value)
          b <- get()
          return({a, b})
        end

      # Run once to generate the log
      runner =
        Run.with_handlers(
          l: EffectLogger.Handler,
          s: {State.Handler, nil}
        )

      first_outcome = computation |> Run.run(runner)

      assert %RunOutcome{
               result: {:initial_value, :updated_value},
               outputs: %{l: _log}
             } = first_outcome

      # Rerun using the outputs (including log) from first run
      second_outcome = Run.rerun(computation, first_outcome)

      # Should get the same result
      assert %RunOutcome{
               result: {:initial_value, :updated_value}
             } = second_outcome

      # The log should be consumed (moved to stack) during replay
      assert %{l: _replayed_log} = second_outcome.outputs
      # IO.puts("\nFirst log:\n#{inspect(log, pretty: true)}")
      # IO.puts("\nReplayed log:\n#{inspect(replayed_log, pretty: true)}")
    end

    test "replays Writer effects from log" do
      computation =
        con [Writer] do
          _ <- tell("first")
          _ <- tell("second")
          _ <- tell("third")
          return(:done)
        end

      runner =
        Run.with_handlers(
          l: EffectLogger.Handler,
          w: Writer.Handler
        )

      first_outcome = computation |> Run.run(runner)

      assert %RunOutcome{
               result: :done,
               outputs: %{l: _log, w: ["third", "second", "first"]}
             } = first_outcome

      # Replay using rerun
      second_outcome = Run.rerun(computation, first_outcome)

      assert %RunOutcome{
               result: :done,
               outputs: %{w: ["third", "second", "first"]}
             } = second_outcome
    end

    test "replays mixed State and Writer effects" do
      computation =
        con [State, Writer] do
          _ <- put(0)
          _ <- tell("starting")
          x <- get()
          _ <- put(x + 10)
          _ <- tell("incremented to 10")
          y <- get()
          _ <- put(y + 20)
          _ <- tell("incremented to 30")
          z <- get()
          return(z)
        end

      runner =
        Run.with_handlers(
          l: EffectLogger.Handler,
          s: {State.Handler, nil},
          w: Writer.Handler
        )

      first_outcome = computation |> Run.run(runner)

      assert %RunOutcome{
               result: 30,
               outputs: %{
                 l: _log,
                 s: 30,
                 w: ["incremented to 30", "incremented to 10", "starting"]
               }
             } = first_outcome

      # Replay using rerun
      second_outcome = Run.rerun(computation, first_outcome)

      assert %RunOutcome{
               result: 30,
               outputs: %{
                 s: 30,
                 w: ["incremented to 30", "incremented to 10", "starting"]
               }
             } = second_outcome
    end
  end

  describe "unscoped effect replay with serialization" do
    test "replays State effects from deserialized log" do
      # Use strings instead of atoms since JSON doesn't preserve atoms
      computation =
        con [State] do
          _ <- put("value_one")
          a <- get()
          _ <- put("value_two")
          b <- get()
          return({a, b})
        end

      runner =
        Run.with_handlers(
          l: EffectLogger.Handler,
          s: {State.Handler, nil}
        )

      first_outcome = computation |> Run.run(runner)

      assert %RunOutcome{
               result: {"value_one", "value_two"},
               outputs: %{l: log, s: state}
             } = first_outcome

      # Serialize and deserialize the outputs
      json = Jason.encode!(%{l: log, s: state})
      decoded_map = Jason.decode!(json)

      deserialized_outputs = %{
        l: Freyja.Effects.EffectLogger.Log.from_json(decoded_map["l"]),
        s: decoded_map["s"]
      }

      # IO.puts("\nOriginal log:\n#{inspect(log, pretty: true)}")
      # IO.puts("\nDeserialized log:\n#{inspect(deserialized_outputs.l, pretty: true)}")

      # Create outcome with deserialized outputs for rerun
      deserialized_outcome = %{first_outcome | outputs: deserialized_outputs}

      # Rerun with deserialized state
      second_outcome = Run.rerun(computation, deserialized_outcome)

      # Should get the same result
      assert %RunOutcome{
               result: {"value_one", "value_two"}
             } = second_outcome
    end

    test "replays Writer effects from deserialized log" do
      computation =
        con [Writer] do
          _ <- tell("alpha")
          _ <- tell("beta")
          _ <- tell("gamma")
          return(:complete)
        end

      runner =
        Run.with_handlers(
          l: EffectLogger.Handler,
          w: Writer.Handler
        )

      first_outcome = computation |> Run.run(runner)

      assert %RunOutcome{
               result: :complete,
               outputs: %{l: log, w: writer_output}
             } = first_outcome

      # Writer output is in reverse order (most recent first)
      assert writer_output == ["gamma", "beta", "alpha"]

      # Serialize and deserialize outputs
      json = Jason.encode!(%{l: log, w: writer_output})
      decoded_map = Jason.decode!(json)

      deserialized_outputs = %{
        l: Freyja.Effects.EffectLogger.Log.from_json(decoded_map["l"]),
        w: decoded_map["w"]
      }

      # Rerun with deserialized state
      deserialized_outcome = %{first_outcome | outputs: deserialized_outputs}
      second_outcome = Run.rerun(computation, deserialized_outcome)

      assert %RunOutcome{
               result: :complete,
               outputs: %{w: ["gamma", "beta", "alpha"]}
             } = second_outcome
    end
  end
end
