defmodule Freyja.Effects.WriterTest do
  use ExUnit.Case

  alias Freyja.Effects.Writer
  alias Freyja.Effects.State
  alias Freyja.Effects.Throw
  alias Freyja.Run

  defmodule WriterExamples do
    import Freyja.Freer.FreerBlock

    defcon single_tell, [Writer] do
      _ <- tell("log entry")
      return(:done)
    end

    defcon multiple_tells, [Writer] do
      _ <- tell("first")
      _ <- tell("second")
      _ <- tell("third")
      return(:done)
    end

    defcon tell_strings, [Writer] do
      _ <- tell("hello")
      _ <- tell("world")
      return(:ok)
    end

    defcon tell_numbers, [Writer] do
      _ <- tell(1)
      _ <- tell(2)
      _ <- tell(3)
      return(:sum)
    end

    defcon tell_maps, [Writer] do
      _ <- tell(%{event: "started", timestamp: 100})
      _ <- tell(%{event: "finished", timestamp: 200})
      return(:done)
    end

    defcon tell_mixed, [Writer] do
      _ <- tell(:atom)
      _ <- tell("string")
      _ <- tell(42)
      _ <- tell(%{key: "value"})
      return(:mixed)
    end

    defcon writer_with_state, [Writer, State] do
      counter <- get()
      _ <- tell({:count, counter})
      _ <- put(counter + 1)
      new_counter <- get()
      _ <- tell({:count, new_counter})
      return(new_counter)
    end

    defcon success_path, [Writer, Throw] do
      _ <- tell("starting")
      result <- return(42)
      _ <- tell("succeeded")
      return(result)
    end

    defcon error_path, [Writer, Throw] do
      _ <- tell("starting")
      _ <- tell("about to error")
      _ <- throw_error(:error)
      _ <- tell("this should not be logged")
      return(:not_reached)
    end

    defcon log_step(msg), [Writer] do
      _ <- tell(msg)
      return(:ok)
    end

    defcon process, [Writer] do
      _ <- log_step("step 1")
      _ <- log_step("step 2")
      _ <- log_step("step 3")
      return(:done)
    end

    defcon divide_success(a, b), [Writer] do
      _ <- tell({:dividing, a, b})
      quotient <- return(Kernel.div(a, b))
      _ <- tell({:result, quotient})
      return({:ok, quotient})
    end

    defcon divide_error(a, b), [Writer] do
      _ <- tell({:dividing, a, b})
      _ <- tell({:error, :division_by_zero})
      return({:error, :division_by_zero})
    end

    defcon branch_a, [Writer] do
      _ <- tell("branch_a start")
      _ <- tell("branch_a end")
      return(:a_done)
    end

    defcon branch_b, [Writer] do
      _ <- tell("branch_b start")
      _ <- tell("branch_b end")
      return(:b_done)
    end

    defcon multi_branch, [Writer] do
      _ <- tell("main start")
      _a <- branch_a()
      _b <- branch_b()
      _ <- tell("main end")
      return(:all_done)
    end

    defcon no_tells, [Writer] do
      return(:no_logs)
    end

    defcon conditional_log(should_log, message), [Writer] do
      _ignored <-
        if should_log do
          tell(message)
        else
          return(nil)
        end

      return(:done)
    end

    defcon audit_trail, [Writer] do
      _ <- tell(%{action: :login, user: "alice", timestamp: 1000})
      _ <- tell(%{action: :read, resource: "/docs", timestamp: 1001})
      _ <- tell(%{action: :write, resource: "/docs", timestamp: 1002})
      _ <- tell(%{action: :logout, user: "alice", timestamp: 1003})
      return(:session_complete)
    end
  end

  describe "Writer effect" do
    test "single tell operation" do
      outcome = Run.run(WriterExamples.single_tell(), [Writer.Handler])

      assert outcome.result == :done
      # Note: Writer accumulates in reverse order (most recent first)
      assert outcome.outputs[Writer.Handler] == ["log entry"]
    end

    test "multiple tell operations accumulate" do
      outcome = Run.run(WriterExamples.multiple_tells(), [Writer.Handler])

      assert outcome.result == :done
      # Most recent first (reverse chronological order)
      assert outcome.outputs[Writer.Handler] == ["third", "second", "first"]
    end

    test "tell with different data types - strings" do
      outcome = Run.run(WriterExamples.tell_strings(), [Writer.Handler])

      assert outcome.outputs[Writer.Handler] == ["world", "hello"]
    end

    test "tell with different data types - numbers" do
      outcome = Run.run(WriterExamples.tell_numbers(), [Writer.Handler])

      assert outcome.outputs[Writer.Handler] == [3, 2, 1]
    end

    test "tell with different data types - maps" do
      outcome = Run.run(WriterExamples.tell_maps(), [Writer.Handler])

      assert outcome.outputs[Writer.Handler] == [
               %{event: "finished", timestamp: 200},
               %{event: "started", timestamp: 100}
             ]
    end

    test "tell with different data types - mixed" do
      outcome = Run.run(WriterExamples.tell_mixed(), [Writer.Handler])

      assert outcome.outputs[Writer.Handler] == [%{key: "value"}, 42, "string", :atom]
    end

    test "Writer with State effect" do
      outcome =
        Run.run(WriterExamples.writer_with_state(), [Writer.Handler, State.Handler], %{
          State.Handler => 0
        })

      assert outcome.result == 1
      assert outcome.outputs[State.Handler] == 1
      assert outcome.outputs[Writer.Handler] == [{:count, 1}, {:count, 0}]
    end

    test "Writer with Error effect - success path" do
      outcome = Run.run(WriterExamples.success_path(), [Writer.Handler])

      assert outcome.result == 42
      assert outcome.outputs[Writer.Handler] == ["succeeded", "starting"]
    end

    test "Writer with Error effect - error path logs until error" do
      outcome = Run.run(WriterExamples.error_path(), [Writer.Handler, Throw.Handler])

      assert outcome.result == {:error, :error}
      # Only logs before the error are captured
      assert outcome.outputs[Writer.Handler] == ["about to error", "starting"]
    end

    test "Writer in nested function calls" do
      outcome = Run.run(WriterExamples.process(), [Writer.Handler])

      assert outcome.result == :done
      assert outcome.outputs[Writer.Handler] == ["step 3", "step 2", "step 1"]
    end

    test "Writer tracks execution flow - success" do
      outcome = Run.run(WriterExamples.divide_success(10, 2), [Writer.Handler])

      assert outcome.result == {:ok, 5}
      assert outcome.outputs[Writer.Handler] == [{:result, 5}, {:dividing, 10, 2}]
    end

    test "Writer tracks execution flow - error case" do
      outcome = Run.run(WriterExamples.divide_error(10, 0), [Writer.Handler])

      assert outcome.result == {:error, :division_by_zero}

      assert outcome.outputs[Writer.Handler] == [
               {:error, :division_by_zero},
               {:dividing, 10, 0}
             ]
    end

    test "Writer accumulates across multiple computation branches" do
      outcome = Run.run(WriterExamples.multi_branch(), [Writer.Handler])

      assert outcome.result == :all_done

      assert outcome.outputs[Writer.Handler] == [
               "main end",
               "branch_b end",
               "branch_b start",
               "branch_a end",
               "branch_a start",
               "main start"
             ]
    end

    test "Writer with initial state" do
      # Start with some existing log entries
      outcome =
        Run.run(WriterExamples.single_tell(), [Writer.Handler], %{
          Writer.Handler => ["existing1", "existing2"]
        })

      assert outcome.result == :done
      # New entries are prepended (most recent first)
      assert outcome.outputs[Writer.Handler] == ["log entry", "existing1", "existing2"]
    end

    test "Writer produces empty output when no tells" do
      outcome = Run.run(WriterExamples.no_tells(), [Writer.Handler])

      assert outcome.result == :no_logs
      assert outcome.outputs[Writer.Handler] == []
    end

    test "Writer with conditional logging - enabled" do
      outcome = Run.run(WriterExamples.conditional_log(true, "logged"), [Writer.Handler])

      assert outcome.result == :done
      assert outcome.outputs[Writer.Handler] == ["logged"]
    end

    test "Writer with conditional logging - disabled" do
      outcome = Run.run(WriterExamples.conditional_log(false, "not logged"), [Writer.Handler])

      assert outcome.result == :done
      assert outcome.outputs[Writer.Handler] == []
    end

    test "Writer can log structured audit trail" do
      outcome = Run.run(WriterExamples.audit_trail(), [Writer.Handler])

      assert outcome.result == :session_complete

      assert outcome.outputs[Writer.Handler] == [
               %{action: :logout, user: "alice", timestamp: 1003},
               %{action: :write, resource: "/docs", timestamp: 1002},
               %{action: :read, resource: "/docs", timestamp: 1001},
               %{action: :login, user: "alice", timestamp: 1000}
             ]
    end
  end
end
