defmodule Freyja.Effects.WriterTest do
  use ExUnit.Case

  alias Freyja.Effects.Writer
  alias Freyja.Effects.State
  alias Freyja.Effects.Error
  alias Freyja.Run

  defmodule WriterExamples do
    import Freyja.Con

    defcon single_tell, [Writer] do
      tell("log entry")
      return(:done)
    end

    defcon multiple_tells, [Writer] do
      tell("first")
      tell("second")
      tell("third")
      return(:done)
    end

    defcon tell_strings, [Writer] do
      tell("hello")
      tell("world")
      return(:ok)
    end

    defcon tell_numbers, [Writer] do
      tell(1)
      tell(2)
      tell(3)
      return(:sum)
    end

    defcon tell_maps, [Writer] do
      tell(%{event: "started", timestamp: 100})
      tell(%{event: "finished", timestamp: 200})
      return(:done)
    end

    defcon tell_mixed, [Writer] do
      tell(:atom)
      tell("string")
      tell(42)
      tell(%{key: "value"})
      return(:mixed)
    end

    defcon writer_with_state, [Writer, State] do
      counter <- get()
      tell({:count, counter})
      put(counter + 1)
      new_counter <- get()
      tell({:count, new_counter})
      return(new_counter)
    end

    defcon success_path, [Writer, Error] do
      tell("starting")
      result <- return(42)
      tell("succeeded")
      return(result)
    end

    defcon error_path, [Writer, Error] do
      tell("starting")
      tell("about to error")
      throw_error(:error)
      tell("this should not be logged")
      return(:not_reached)
    end

    defcon log_step(msg), [Writer] do
      tell(msg)
      return(:ok)
    end

    defcon process, [Writer] do
      log_step("step 1")
      log_step("step 2")
      log_step("step 3")
      return(:done)
    end

    defcon divide_success(a, b), [Writer] do
      tell({:dividing, a, b})
      quotient <- return(Kernel.div(a, b))
      tell({:result, quotient})
      return({:ok, quotient})
    end

    defcon divide_error(a, b), [Writer] do
      tell({:dividing, a, b})
      tell({:error, :division_by_zero})
      return({:error, :division_by_zero})
    end

    defcon branch_a, [Writer] do
      tell("branch_a start")
      tell("branch_a end")
      return(:a_done)
    end

    defcon branch_b, [Writer] do
      tell("branch_b start")
      tell("branch_b end")
      return(:b_done)
    end

    defcon multi_branch, [Writer] do
      tell("main start")
      _a <- branch_a()
      _b <- branch_b()
      tell("main end")
      return(:all_done)
    end

    defcon no_tells, [Writer] do
      return(:no_logs)
    end

    defcon conditional_log(should_log, message), [Writer] do
      _ <-
        if should_log do
          tell(message)
        else
          return(nil)
        end

      return(:done)
    end

    defcon audit_trail, [Writer] do
      tell(%{action: :login, user: "alice", timestamp: 1000})
      tell(%{action: :read, resource: "/docs", timestamp: 1001})
      tell(%{action: :write, resource: "/docs", timestamp: 1002})
      tell(%{action: :logout, user: "alice", timestamp: 1003})
      return(:session_complete)
    end
  end

  describe "Writer effect" do
    test "single tell operation" do
      runner = Run.with_handlers(w: {Writer.Handler, []})
      outcome = Run.run(WriterExamples.single_tell(), runner)

      assert outcome.result == %Freyja.OkResult{value: :done}
      # Note: Writer accumulates in reverse order (most recent first)
      assert outcome.outputs.w == ["log entry"]
    end

    test "multiple tell operations accumulate" do
      runner = Run.with_handlers(w: {Writer.Handler, []})
      outcome = Run.run(WriterExamples.multiple_tells(), runner)

      assert outcome.result == %Freyja.OkResult{value: :done}
      # Most recent first (reverse chronological order)
      assert outcome.outputs.w == ["third", "second", "first"]
    end

    test "tell with different data types - strings" do
      runner = Run.with_handlers(w: {Writer.Handler, []})
      outcome = Run.run(WriterExamples.tell_strings(), runner)

      assert outcome.outputs.w == ["world", "hello"]
    end

    test "tell with different data types - numbers" do
      runner = Run.with_handlers(w: {Writer.Handler, []})
      outcome = Run.run(WriterExamples.tell_numbers(), runner)

      assert outcome.outputs.w == [3, 2, 1]
    end

    test "tell with different data types - maps" do
      runner = Run.with_handlers(w: {Writer.Handler, []})
      outcome = Run.run(WriterExamples.tell_maps(), runner)

      assert outcome.outputs.w == [
               %{event: "finished", timestamp: 200},
               %{event: "started", timestamp: 100}
             ]
    end

    test "tell with different data types - mixed" do
      runner = Run.with_handlers(w: {Writer.Handler, []})
      outcome = Run.run(WriterExamples.tell_mixed(), runner)

      assert outcome.outputs.w == [%{key: "value"}, 42, "string", :atom]
    end

    test "Writer with State effect" do
      runner =
        Run.with_handlers(
          w: {Writer.Handler, []},
          s: {State.Handler, 0}
        )

      outcome = Run.run(WriterExamples.writer_with_state(), runner)

      assert outcome.result == %Freyja.OkResult{value: 1}
      assert outcome.outputs.s == 1
      assert outcome.outputs.w == [{:count, 1}, {:count, 0}]
    end

    test "Writer with Error effect - success path" do
      runner = Run.with_handlers(w: {Writer.Handler, []})
      outcome = Run.run(WriterExamples.success_path(), runner)

      assert outcome.result == %Freyja.OkResult{value: 42}
      assert outcome.outputs.w == ["succeeded", "starting"]
    end

    test "Writer with Error effect - error path logs until error" do
      runner = Run.with_handlers(w: {Writer.Handler, []}, e: Error.Handler)
      outcome = Run.run(WriterExamples.error_path(), runner)

      assert outcome.result == %Freyja.ErrorResult{error: :error}
      # Only logs before the error are captured
      assert outcome.outputs.w == ["about to error", "starting"]
    end

    test "Writer in nested function calls" do
      runner = Run.with_handlers(w: {Writer.Handler, []})
      outcome = Run.run(WriterExamples.process(), runner)

      assert outcome.result == %Freyja.OkResult{value: :done}
      assert outcome.outputs.w == ["step 3", "step 2", "step 1"]
    end

    test "Writer tracks execution flow - success" do
      runner = Run.with_handlers(w: {Writer.Handler, []})
      outcome = Run.run(WriterExamples.divide_success(10, 2), runner)

      assert outcome.result == %Freyja.OkResult{value: {:ok, 5}}
      assert outcome.outputs.w == [{:result, 5}, {:dividing, 10, 2}]
    end

    test "Writer tracks execution flow - error case" do
      runner = Run.with_handlers(w: {Writer.Handler, []})
      outcome = Run.run(WriterExamples.divide_error(10, 0), runner)

      assert outcome.result == %Freyja.OkResult{value: {:error, :division_by_zero}}

      assert outcome.outputs.w == [
               {:error, :division_by_zero},
               {:dividing, 10, 0}
             ]
    end

    test "Writer accumulates across multiple computation branches" do
      runner = Run.with_handlers(w: {Writer.Handler, []})
      outcome = Run.run(WriterExamples.multi_branch(), runner)

      assert outcome.result == %Freyja.OkResult{value: :all_done}

      assert outcome.outputs.w == [
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
      runner = Run.with_handlers(w: {Writer.Handler, ["existing1", "existing2"]})
      outcome = Run.run(WriterExamples.single_tell(), runner)

      assert outcome.result == %Freyja.OkResult{value: :done}
      # New entries are prepended (most recent first)
      assert outcome.outputs.w == ["log entry", "existing1", "existing2"]
    end

    test "Writer produces empty output when no tells" do
      runner = Run.with_handlers(w: {Writer.Handler, []})
      outcome = Run.run(WriterExamples.no_tells(), runner)

      assert outcome.result == %Freyja.OkResult{value: :no_logs}
      assert outcome.outputs.w == []
    end

    test "Writer with conditional logging - enabled" do
      runner = Run.with_handlers(w: {Writer.Handler, []})
      outcome = Run.run(WriterExamples.conditional_log(true, "logged"), runner)

      assert outcome.result == %Freyja.OkResult{value: :done}
      assert outcome.outputs.w == ["logged"]
    end

    test "Writer with conditional logging - disabled" do
      runner = Run.with_handlers(w: {Writer.Handler, []})
      outcome = Run.run(WriterExamples.conditional_log(false, "not logged"), runner)

      assert outcome.result == %Freyja.OkResult{value: :done}
      assert outcome.outputs.w == []
    end

    test "Writer can log structured audit trail" do
      runner = Run.with_handlers(w: {Writer.Handler, []})
      outcome = Run.run(WriterExamples.audit_trail(), runner)

      assert outcome.result == %Freyja.OkResult{value: :session_complete}

      assert outcome.outputs.w == [
               %{action: :logout, user: "alice", timestamp: 1003},
               %{action: :write, resource: "/docs", timestamp: 1002},
               %{action: :read, resource: "/docs", timestamp: 1001},
               %{action: :login, user: "alice", timestamp: 1000}
             ]
    end
  end
end
