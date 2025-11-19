defmodule Freyja.Effects.TaggedWriterTest do
  use ExUnit.Case

  import Freyja.Con
  import Freyja.HeftyMacro

  alias Freyja.Effects.TaggedWriter
  alias Freyja.Effects.Writer
  alias Freyja.Effects.State
  alias Freyja.Effects.Reader
  alias Freyja.Effects.Error
  alias Freyja.Run
  alias Freyja.Hefty
  alias Freyja.Effects.Lift

  # Helper to create Hefty runner for tests with listen
  defp hefty_runner_with_tagged_writer(initial_tw_state \\ %{}, other_handlers \\ []) do
    algebras = [Lift.Algebra, TaggedWriter.Algebra]

    handlers = [
      TaggedWriter.Handler,
      TaggedWriter.RunListenHandler
      | other_handlers
    ]

    initial_states = %{TaggedWriter.Handler => initial_tw_state}

    {algebras, handlers, initial_states}
  end

  # Helper to add State handler to Hefty runner
  defp add_state_handler({algebras, handlers, states}, initial_state) do
    {algebras, [State.Handler | handlers], Map.put(states, State.Handler, initial_state)}
  end

  # Basic operations
  defcon single_tell_tagged, [TaggedWriter] do
    _ <- tell(:audit, "user logged in")
    return(:done)
  end

  defcon multiple_tells_same_tag, [TaggedWriter] do
    _ <- tell(:debug, "step 1")
    _ <- tell(:debug, "step 2")
    _ <- tell(:debug, "step 3")
    return(:done)
  end

  defcon multiple_tells_different_tags, [TaggedWriter] do
    _ <- tell(:audit, "login")
    _ <- tell(:debug, "processing")
    _ <- tell(:metrics, %{duration: 100})
    _ <- tell(:audit, "logout")
    _ <- tell(:debug, "done")
    return(:done)
  end

  # Different value types
  defcon tell_strings, [TaggedWriter] do
    _ <- tell(:log, "hello")
    _ <- tell(:log, "world")
    return(:ok)
  end

  defcon tell_numbers, [TaggedWriter] do
    _ <- tell(:counters, 1)
    _ <- tell(:counters, 2)
    _ <- tell(:counters, 3)
    return(:ok)
  end

  defcon tell_maps, [TaggedWriter] do
    _ <- tell(:events, %{event: "started", timestamp: 100})
    _ <- tell(:events, %{event: "finished", timestamp: 200})
    return(:ok)
  end

  defcon tell_mixed_types, [TaggedWriter] do
    _ <- tell(:mixed, :atom)
    _ <- tell(:mixed, "string")
    _ <- tell(:mixed, 42)
    _ <- tell(:mixed, %{key: "value"})
    return(:ok)
  end

  # Composition with other effects
  defcon writer_with_state, [TaggedWriter, State] do
    counter <- State.get()
    _ <- tell(:operations, {:get, counter})

    _ <- State.put(counter + 1)
    new_counter <- State.get()
    _ <- tell(:operations, {:put, new_counter})

    return(new_counter)
  end

  defcon writer_with_reader, [TaggedWriter, Reader] do
    env <- Reader.ask()
    _ <- tell(:access, {:read_env, env})
    result <- return(env.multiplier * 2)
    _ <- tell(:calculations, {:computed, result})
    return(result)
  end

  defcon success_with_writer, [TaggedWriter, Error] do
    _ <- tell(:trace, "starting")
    result <- return(42)
    _ <- tell(:trace, "succeeded")
    return(result)
  end

  defcon error_with_writer, [TaggedWriter, Error] do
    _ <- tell(:trace, "starting")
    _ <- tell(:trace, "about to error")
    _ <- Error.throw_error(:boom)
    _ <- tell(:trace, "never logged")
    return(:not_reached)
  end

  defcon all_effects, [TaggedWriter, State, Reader] do
    multiplier <- Reader.ask()
    counter <- State.get()

    _ <- tell(:audit, {:reading, counter})

    result <- return(counter * multiplier)

    _ <- tell(:audit, {:computed, result})
    _ <- State.put(result)

    return(result)
  end

  # Nested computations
  defcon log_step(tag, msg), [TaggedWriter] do
    _ <- tell(tag, msg)
    return(:ok)
  end

  defcon process_steps, [TaggedWriter] do
    _ <- log_step(:workflow, "step 1")
    _ <- log_step(:workflow, "step 2")
    _ <- log_step(:workflow, "step 3")
    return(:done)
  end

  defcon branch_a, [TaggedWriter] do
    _ <- tell(:branches, "branch_a start")
    _ <- tell(:branches, "branch_a end")
    return(:a_done)
  end

  defcon branch_b, [TaggedWriter] do
    _ <- tell(:branches, "branch_b start")
    _ <- tell(:branches, "branch_b end")
    return(:b_done)
  end

  defcon multi_branch, [TaggedWriter] do
    _ <- tell(:main, "main start")
    _a <- branch_a()
    _b <- branch_b()
    _ <- tell(:main, "main end")
    return(:all_done)
  end

  # Complex scenarios
  defcon audit_trail, [TaggedWriter] do
    _ <- tell(:audit, %{action: :login, user: "alice", timestamp: 1000})
    _ <- tell(:debug, "user alice authenticated")

    _ <- tell(:audit, %{action: :read, resource: "/docs", timestamp: 1001})
    _ <- tell(:debug, "accessed /docs")

    _ <- tell(:audit, %{action: :write, resource: "/docs", timestamp: 1002})
    _ <- tell(:metrics, %{operation: :write, duration_ms: 45})

    _ <- tell(:audit, %{action: :logout, user: "alice", timestamp: 1003})
    _ <- tell(:debug, "user alice logged out")

    return(:session_complete)
  end

  defcon multi_tenant_logs(tenant_id, action), [TaggedWriter] do
    _ <- tell({:tenant, tenant_id}, %{action: action, timestamp: System.system_time(:millisecond)})
    _ <- tell(:global, %{tenant: tenant_id, action: action})
    return(:logged)
  end

  # Empty logs
  defcon no_tells, [TaggedWriter] do
    return(:no_logs)
  end

  # Conditional logging
  defcon conditional_log(should_log, tag, message), [TaggedWriter] do
    _ignored <-
      if should_log do
        tell(tag, message)
      else
        return(nil)
      end

    return(:done)
  end

  # Initial state
  defcon append_to_existing, [TaggedWriter] do
    _ <- tell(:log, "new entry")
    return(:ok)
  end

  # Tag types
  defcon use_atom_tag, [TaggedWriter] do
    _ <- tell(:atom_tag, "value")
    return(:ok)
  end

  defcon use_string_tag, [TaggedWriter] do
    _ <- tell("string_tag", "value")
    return(:ok)
  end

  defcon use_number_tag, [TaggedWriter] do
    _ <- tell(1, "first")
    _ <- tell(2, "second")
    return(:ok)
  end

  defcon use_tuple_tag, [TaggedWriter] do
    _ <- tell({:user, 123}, "alice action")
    _ <- tell({:user, 456}, "bob action")
    return(:ok)
  end

  # Comparison with regular Writer
  defcon use_both_writers, [Writer, TaggedWriter] do
    # Regular writer
    _ <- Writer.tell("global log")

    # Tagged writer
    _ <- tell(:audit, "audit entry")
    _ <- tell(:debug, "debug entry")

    _ <- Writer.tell("another global log")
    _ <- tell(:audit, "another audit entry")

    return(:done)
  end

  defcon trigger_error, [TaggedWriter] do
    _ <- tell(:log, "entry")
    return(:ok)
  end

  # Listen operations
  # Listen operations - migrated to Hefty
  defhefty simple_listen do
    TaggedWriter.listen(hefty do
      _ <- TaggedWriter.tell(:audit, "inner1")
      _ <- TaggedWriter.tell(:audit, "inner2")
      return(42)
    end)
  end

  defhefty listen_with_outer_logs do
    _ <- TaggedWriter.tell(:audit, "before")

    {result, inner_logs} <- TaggedWriter.listen(hefty do
      _ <- TaggedWriter.tell(:audit, "inner1")
      _ <- TaggedWriter.tell(:audit, "inner2")
      return(100)
    end)

    _ <- TaggedWriter.tell(:audit, "after")

    return({result, inner_logs})
  end

  defhefty nested_listen do
    _ <- TaggedWriter.tell(:log, "outer start")

    {r1, logs1} <- TaggedWriter.listen(hefty do
      _ <- TaggedWriter.tell(:log, "level1 start")

      {r2, logs2} <- TaggedWriter.listen(hefty do
        _ <- TaggedWriter.tell(:log, "level2")
        return(2)
      end)

      _ <- TaggedWriter.tell(:log, "level1 end")
      return({r2, logs2})
    end)

    _ <- TaggedWriter.tell(:log, "outer end")

    return({r1, logs1})
  end

  defhefty listen_multiple_tags do
    {result, all_logs} <- TaggedWriter.listen(hefty do
      _ <- TaggedWriter.tell(:audit, "a1")
      _ <- TaggedWriter.tell(:debug, "d1")
      _ <- TaggedWriter.tell(:audit, "a2")
      _ <- TaggedWriter.tell(:debug, "d2")
      _ <- TaggedWriter.tell(:audit, "a3")
      _ <- TaggedWriter.tell(:debug, "d3")
      return(:done)
    end)

    return({result, all_logs})
  end

  defhefty listen_with_state do
    _ <- State.put(0)

    {result, logs} <- TaggedWriter.listen(hefty do
      count1 <- State.get()
      _ <- State.put(count1 + 1)
      _ <- TaggedWriter.tell(:counter, {:count, count1})

      count2 <- State.get()
      _ <- State.put(count2 + 1)
      _ <- TaggedWriter.tell(:counter, {:count, count2})

      State.get()
    end)

    return({result, logs})
  end

  # Peek operations
  defcon peek_empty_tag, [TaggedWriter] do
    peek(:nonexistent)
  end

  defcon peek_after_tells, [TaggedWriter] do
    _ <- tell(:log, "first")
    _ <- tell(:log, "second")
    logs <- peek(:log)
    return(logs)
  end

  defcon peek_multiple_tags, [TaggedWriter] do
    _ <- tell(:audit, "a1")
    _ <- tell(:debug, "d1")
    _ <- tell(:audit, "a2")

    audit_logs <- peek(:audit)
    debug_logs <- peek(:debug)

    return(%{audit: audit_logs, debug: debug_logs})
  end

  defcon peek_in_between_tells, [TaggedWriter] do
    _ <- tell(:log, "first")
    logs1 <- peek(:log)

    _ <- tell(:log, "second")
    logs2 <- peek(:log)

    _ <- tell(:log, "third")
    logs3 <- peek(:log)

    return({logs1, logs2, logs3})
  end

  defcon conditional_log_based_on_peek, [TaggedWriter] do
    _ <- tell(:errors, "error1")

    current_errors <- peek(:errors)
    error_count <- return(length(current_errors))

    _ignored <- if error_count > 0 do
      tell(:alerts, "Alert: #{error_count} errors occurred")
    else
      return(nil)
    end

    return(error_count)
  end

  # Tests
  describe "basic tagged writer operations" do
    test "single tell operation" do
      runner =
        Run.with_handlers(
          tw: {TaggedWriter.Handler, %{}}
        )

      outcome = Run.run(single_tell_tagged(), runner)

      assert outcome.result == :done
      assert outcome.outputs.tw == %{audit: ["user logged in"]}
    end

    test "multiple tells to same tag accumulate" do
      runner =
        Run.with_handlers(
          tw: {TaggedWriter.Handler, %{}}
        )

      outcome = Run.run(multiple_tells_same_tag(), runner)

      assert outcome.result == :done
      # Most recent first (reverse chronological order)
      assert outcome.outputs.tw == %{debug: ["step 3", "step 2", "step 1"]}
    end

    test "multiple tells to different tags" do
      runner =
        Run.with_handlers(
          tw: {TaggedWriter.Handler, %{}}
        )

      outcome = Run.run(multiple_tells_different_tags(), runner)

      assert outcome.result == :done
      assert outcome.outputs.tw == %{
        audit: ["logout", "login"],
        debug: ["done", "processing"],
        metrics: [%{duration: 100}]
      }
    end
  end

  describe "different value types" do
    test "tell strings" do
      runner = Run.with_handlers(tw: {TaggedWriter.Handler, %{}})
      outcome = Run.run(tell_strings(), runner)

      assert outcome.outputs.tw == %{log: ["world", "hello"]}
    end

    test "tell numbers" do
      runner = Run.with_handlers(tw: {TaggedWriter.Handler, %{}})
      outcome = Run.run(tell_numbers(), runner)

      assert outcome.outputs.tw == %{counters: [3, 2, 1]}
    end

    test "tell maps" do
      runner = Run.with_handlers(tw: {TaggedWriter.Handler, %{}})
      outcome = Run.run(tell_maps(), runner)

      assert outcome.outputs.tw == %{
        events: [
          %{event: "finished", timestamp: 200},
          %{event: "started", timestamp: 100}
        ]
      }
    end

    test "tell mixed types" do
      runner = Run.with_handlers(tw: {TaggedWriter.Handler, %{}})
      outcome = Run.run(tell_mixed_types(), runner)

      assert outcome.outputs.tw == %{mixed: [%{key: "value"}, 42, "string", :atom]}
    end
  end

  describe "composition with other effects" do
    test "TaggedWriter with State" do
      runner =
        Run.with_handlers(
          tw: {TaggedWriter.Handler, %{}},
          s: {State.Handler, 5}
        )

      outcome = Run.run(writer_with_state(), runner)

      assert outcome.result == 6
      assert outcome.outputs.s == 6
      assert outcome.outputs.tw == %{operations: [{:put, 6}, {:get, 5}]}
    end

    test "TaggedWriter with Reader" do
      runner =
        Run.with_handlers(
          tw: {TaggedWriter.Handler, %{}},
          r: {Reader.Handler, %{multiplier: 3}}
        )

      outcome = Run.run(writer_with_reader(), runner)

      assert outcome.result == 6
      assert outcome.outputs.tw == %{
        calculations: [{:computed, 6}],
        access: [{:read_env, %{multiplier: 3}}]
      }
    end

    test "TaggedWriter with Error effect - success path" do
      runner = Run.with_handlers(tw: {TaggedWriter.Handler, %{}})
      outcome = Run.run(success_with_writer(), runner)

      assert outcome.result == 42
      assert outcome.outputs.tw == %{trace: ["succeeded", "starting"]}
    end

    test "TaggedWriter with Error effect - error path logs until error" do
      runner =
        Run.with_handlers(
          tw: {TaggedWriter.Handler, %{}},
          e: Error.Handler
        )

      outcome = Run.run(error_with_writer(), runner)

      assert outcome.result == {:error, :boom}
      # Only logs before the error are captured
      assert outcome.outputs.tw == %{trace: ["about to error", "starting"]}
    end

    test "TaggedWriter with State and Reader" do
      runner =
        Run.with_handlers(
          tw: {TaggedWriter.Handler, %{}},
          s: {State.Handler, 7},
          r: {Reader.Handler, 4}
        )

      outcome = Run.run(all_effects(), runner)

      assert outcome.result == 28
      assert outcome.outputs.s == 28
      assert outcome.outputs.tw == %{audit: [{:computed, 28}, {:reading, 7}]}
    end

    test "TaggedWriter with regular Writer" do
      runner =
        Run.with_handlers(
          w: {Writer.Handler, []},
          tw: {TaggedWriter.Handler, %{}}
        )

      outcome = Run.run(use_both_writers(), runner)

      assert outcome.result == :done
      assert outcome.outputs.w == ["another global log", "global log"]
      assert outcome.outputs.tw == %{
        audit: ["another audit entry", "audit entry"],
        debug: ["debug entry"]
      }
    end
  end

  describe "nested computations" do
    test "nested function calls accumulate logs" do
      runner = Run.with_handlers(tw: {TaggedWriter.Handler, %{}})
      outcome = Run.run(process_steps(), runner)

      assert outcome.result == :done
      assert outcome.outputs.tw == %{workflow: ["step 3", "step 2", "step 1"]}
    end

    test "logs accumulate across multiple branches" do
      runner = Run.with_handlers(tw: {TaggedWriter.Handler, %{}})
      outcome = Run.run(multi_branch(), runner)

      assert outcome.result == :all_done
      assert outcome.outputs.tw == %{
        main: ["main end", "main start"],
        branches: [
          "branch_b end",
          "branch_b start",
          "branch_a end",
          "branch_a start"
        ]
      }
    end
  end

  describe "complex scenarios" do
    test "structured audit trail with multiple log streams" do
      runner = Run.with_handlers(tw: {TaggedWriter.Handler, %{}})
      outcome = Run.run(audit_trail(), runner)

      assert outcome.result == :session_complete

      assert outcome.outputs.tw.audit == [
        %{action: :logout, user: "alice", timestamp: 1003},
        %{action: :write, resource: "/docs", timestamp: 1002},
        %{action: :read, resource: "/docs", timestamp: 1001},
        %{action: :login, user: "alice", timestamp: 1000}
      ]

      assert outcome.outputs.tw.debug == [
        "user alice logged out",
        "accessed /docs",
        "user alice authenticated"
      ]

      assert outcome.outputs.tw.metrics == [%{operation: :write, duration_ms: 45}]
    end

    test "multi-tenant logging with tuple tags" do
      runner = Run.with_handlers(tw: {TaggedWriter.Handler, %{}})

      # Log actions for different tenants
      outcome1 = Run.run(multi_tenant_logs("tenant_a", :create), runner)
      runner2 = %{runner | states: %{tw: outcome1.outputs.tw}}

      outcome2 = Run.run(multi_tenant_logs("tenant_b", :update), runner2)
      runner3 = %{runner | states: %{tw: outcome2.outputs.tw}}

      outcome3 = Run.run(multi_tenant_logs("tenant_a", :delete), runner3)

      assert outcome3.result == :logged

      # Check tenant-specific logs
      assert length(outcome3.outputs.tw[{:tenant, "tenant_a"}]) == 2
      assert length(outcome3.outputs.tw[{:tenant, "tenant_b"}]) == 1
      assert length(outcome3.outputs.tw[:global]) == 3
    end
  end

  describe "edge cases" do
    test "no tells produces empty map output" do
      runner = Run.with_handlers(tw: {TaggedWriter.Handler, %{}})
      outcome = Run.run(no_tells(), runner)

      assert outcome.result == :no_logs
      assert outcome.outputs.tw == %{}
    end

    test "conditional logging - enabled" do
      runner = Run.with_handlers(tw: {TaggedWriter.Handler, %{}})
      outcome = Run.run(conditional_log(true, :log, "logged"), runner)

      assert outcome.result == :done
      assert outcome.outputs.tw == %{log: ["logged"]}
    end

    test "conditional logging - disabled" do
      runner = Run.with_handlers(tw: {TaggedWriter.Handler, %{}})
      outcome = Run.run(conditional_log(false, :log, "not logged"), runner)

      assert outcome.result == :done
      assert outcome.outputs.tw == %{}
    end

    test "append to existing tagged logs" do
      runner = Run.with_handlers(tw: {TaggedWriter.Handler, %{log: ["existing1", "existing2"]}})
      outcome = Run.run(append_to_existing(), runner)

      assert outcome.result == :ok
      # New entries are prepended
      assert outcome.outputs.tw == %{log: ["new entry", "existing1", "existing2"]}
    end
  end

  describe "tag types" do
    test "supports atom tags" do
      runner = Run.with_handlers(tw: {TaggedWriter.Handler, %{}})
      outcome = Run.run(use_atom_tag(), runner)

      assert outcome.outputs.tw == %{atom_tag: ["value"]}
    end

    test "supports string tags" do
      runner = Run.with_handlers(tw: {TaggedWriter.Handler, %{}})
      outcome = Run.run(use_string_tag(), runner)

      assert outcome.outputs.tw == %{"string_tag" => ["value"]}
    end

    test "supports number tags" do
      runner = Run.with_handlers(tw: {TaggedWriter.Handler, %{}})
      outcome = Run.run(use_number_tag(), runner)

      assert outcome.outputs.tw == %{1 => ["first"], 2 => ["second"]}
    end

    test "supports tuple tags" do
      runner = Run.with_handlers(tw: {TaggedWriter.Handler, %{}})
      outcome = Run.run(use_tuple_tag(), runner)

      assert outcome.outputs.tw == %{
        {:user, 123} => ["alice action"],
        {:user, 456} => ["bob action"]
      }
    end
  end

  describe "error handling" do
    test "raises ArgumentError if handler state is not a map" do
      runner =
        Run.with_handlers(
          tw: {TaggedWriter.Handler, "not a map"}
        )

      assert_raise ArgumentError, ~r/TaggedWriter.Handler state must be a map/, fn ->
        Run.run(trigger_error(), runner)
      end
    end
  end

  describe "listen operation" do
    test "simple listen captures inner logs for all tags" do
      {algebras, handlers, initial_states} = hefty_runner_with_tagged_writer()
      outcome = Hefty.Run.run(simple_listen(), algebras, handlers, initial_states)

      {result, captured_logs} = outcome.result

      assert result == 42
      assert captured_logs == %{audit: ["inner2", "inner1"]}
      # Inner logs should also be added to final output
      assert outcome.outputs[TaggedWriter.Handler] == %{audit: ["inner2", "inner1"]}
    end

    test "listen separates inner and outer logs" do
      {algebras, handlers, initial_states} = hefty_runner_with_tagged_writer()
      outcome = Hefty.Run.run(listen_with_outer_logs(), algebras, handlers, initial_states)

      {result, inner_logs} = outcome.result

      assert result == 100
      # Inner logs are captured separately (map with audit tag)
      assert inner_logs == %{audit: ["inner2", "inner1"]}
      # Final output has all logs in order
      assert outcome.outputs[TaggedWriter.Handler] == %{audit: ["after", "inner2", "inner1", "before"]}
    end

    test "nested listen operations" do
      {algebras, handlers, initial_states} = hefty_runner_with_tagged_writer()
      outcome = Hefty.Run.run(nested_listen(), algebras, handlers, initial_states)

      {{level2_result, level2_logs}, level1_logs} = outcome.result

      assert level2_result == 2
      assert level2_logs == %{log: ["level2"]}
      assert level1_logs == %{log: ["level1 end", "level2", "level1 start"]}

      # Final output has everything
      assert outcome.outputs[TaggedWriter.Handler] == %{
        log: ["outer end", "level1 end", "level2", "level1 start", "outer start"]
      }
    end

    test "listen captures multiple tags simultaneously" do
      {algebras, handlers, initial_states} = hefty_runner_with_tagged_writer()
      outcome = Hefty.Run.run(listen_multiple_tags(), algebras, handlers, initial_states)

      {result, all_logs} = outcome.result

      assert result == :done
      # All tags captured in one map
      assert all_logs == %{
        audit: ["a3", "a2", "a1"],
        debug: ["d3", "d2", "d1"]
      }

      # Final outputs have all logs
      tw_output = outcome.outputs[TaggedWriter.Handler]
      assert tw_output.audit == ["a3", "a2", "a1"]
      assert tw_output.debug == ["d3", "d2", "d1"]
    end

    test "listen with State effect" do
      {algebras, handlers, initial_states} = hefty_runner_with_tagged_writer()
      {algebras, handlers, initial_states} = add_state_handler({algebras, handlers, initial_states}, 0)

      outcome = Hefty.Run.run(listen_with_state(), algebras, handlers, initial_states)

      {result, logs} = outcome.result

      assert result == 2
      assert logs == %{counter: [{:count, 1}, {:count, 0}]}
      assert outcome.outputs[State.Handler] == 2
    end

    test "listen with empty inner computation" do
      {algebras, handlers, initial_states} = hefty_runner_with_tagged_writer()

      computation = hefty do
        TaggedWriter.listen(return(:empty))
      end

      outcome = Hefty.Run.run(computation, algebras, handlers, initial_states)

      {result, logs} = outcome.result

      assert result == :empty
      assert logs == %{}
      assert outcome.outputs[TaggedWriter.Handler] == %{}
    end

    test "listen captures all tags written inside" do
      {algebras, handlers, initial_states} = hefty_runner_with_tagged_writer()

      computation = hefty do
        {result, all_logs} <- TaggedWriter.listen(hefty do
          _ <- TaggedWriter.tell(:audit, "audit1")
          _ <- TaggedWriter.tell(:debug, "debug1")
          _ <- TaggedWriter.tell(:audit, "audit2")
          _ <- TaggedWriter.tell(:metrics, "metric1")
          return(:done)
        end)

        return({result, all_logs})
      end

      outcome = Hefty.Run.run(computation, algebras, handlers, initial_states)

      {result, captured_logs} = outcome.result

      assert result == :done
      # All tags captured
      assert captured_logs == %{
        audit: ["audit2", "audit1"],
        debug: ["debug1"],
        metrics: ["metric1"]
      }

      # All logs present in final output
      tw_output = outcome.outputs[TaggedWriter.Handler]
      assert tw_output == %{
        audit: ["audit2", "audit1"],
        debug: ["debug1"],
        metrics: ["metric1"]
      }
    end
  end

  describe "peek operation" do
    test "peek returns empty list for nonexistent tag" do
      runner = Run.with_handlers(tw: {TaggedWriter.Handler, %{}})
      outcome = Run.run(peek_empty_tag(), runner)

      assert outcome.result == []
    end

    test "peek returns current logs after tells" do
      runner = Run.with_handlers(tw: {TaggedWriter.Handler, %{}})
      outcome = Run.run(peek_after_tells(), runner)

      # Should return logs in reverse chronological order
      assert outcome.result == ["second", "first"]
    end

    test "peek can query multiple different tags" do
      runner = Run.with_handlers(tw: {TaggedWriter.Handler, %{}})
      outcome = Run.run(peek_multiple_tags(), runner)

      assert outcome.result == %{
        audit: ["a2", "a1"],
        debug: ["d1"]
      }
    end

    test "peek shows accumulating logs at different points" do
      runner = Run.with_handlers(tw: {TaggedWriter.Handler, %{}})
      outcome = Run.run(peek_in_between_tells(), runner)

      {logs1, logs2, logs3} = outcome.result

      assert logs1 == ["first"]
      assert logs2 == ["second", "first"]
      assert logs3 == ["third", "second", "first"]
    end

    test "peek doesn't modify the log state" do
      runner = Run.with_handlers(tw: {TaggedWriter.Handler, %{}})

      computation = con [TaggedWriter] do
        _ <- tell(:log, "entry")
        _peek1 <- peek(:log)
        _peek2 <- peek(:log)
        _peek3 <- peek(:log)
        return(:ok)
      end

      outcome = Run.run(computation, runner)

      # Final output should still have just one entry
      assert outcome.outputs.tw == %{log: ["entry"]}
    end

    test "peek with initial state" do
      runner = Run.with_handlers(tw: {TaggedWriter.Handler, %{log: ["existing"]}})

      computation = con [TaggedWriter] do
        logs <- peek(:log)
        return(logs)
      end

      outcome = Run.run(computation, runner)

      assert outcome.result == ["existing"]
    end

    test "conditional logging based on peek" do
      runner = Run.with_handlers(tw: {TaggedWriter.Handler, %{}})
      outcome = Run.run(conditional_log_based_on_peek(), runner)

      assert outcome.result == 1
      assert outcome.outputs.tw == %{
        errors: ["error1"],
        alerts: ["Alert: 1 errors occurred"]
      }
    end

    test "peek with composition - State and TaggedWriter" do
      runner = Run.with_handlers(
        tw: {TaggedWriter.Handler, %{}},
        s: {State.Handler, 0}
      )

      computation = con [TaggedWriter, State] do
        _ <- tell(:log, "start")

        logs <- peek(:log)
        _ <- State.put(length(logs))

        _ <- tell(:log, "end")

        final_count <- State.get()
        return(final_count)
      end

      outcome = Run.run(computation, runner)

      assert outcome.result == 1
      assert outcome.outputs.s == 1
      assert outcome.outputs.tw == %{log: ["end", "start"]}
    end
  end
end
