defmodule Freyja.Effects.TaggedStateTest do
  use ExUnit.Case

  import Freyja.Con

  alias Freyja.Effects.TaggedState
  alias Freyja.Effects.State
  alias Freyja.Effects.Reader
  alias Freyja.Effects.Writer
  alias Freyja.Run

  # Basic operations
  defcon get_and_increment_cache, [TaggedState] do
    val <- get(:cache)
    put(:cache, val + 10)
    new_val <- get(:cache)
    return(new_val)
  end

  defcon put_and_return_old, [TaggedState] do
    old_val <- put(:counter, 100)
    return(old_val)
  end

  defcon get_missing_tag, [TaggedState] do
    val <- get(:missing)
    return(val)
  end

  # Multiple tagged states
  defcon manage_multiple_states, [TaggedState] do
    # Read from multiple tags
    cache <- TaggedState.get(:cache)
    config <- TaggedState.get(:config)
    session <- TaggedState.get(:session_id)

    # Update multiple tags
    TaggedState.put(:cache, Map.put(cache, :new_key, "new_value"))
    TaggedState.put(:session_id, session + 1)

    # Read updated values
    new_cache <- TaggedState.get(:cache)
    new_session <- TaggedState.get(:session_id)

    return(%{cache: new_cache, config: config, session: new_session})
  end

  defcon put_different_types, [TaggedState] do
    TaggedState.put(:number, 42)
    TaggedState.put(:string, "hello")
    TaggedState.put(:list, [1, 2, 3])
    TaggedState.put(:map, %{a: 1})
    TaggedState.put(:tuple, {:ok, "result"})
    return(:ok)
  end

  # Composition with other effects
  defcon use_state_and_tagged_state, [State, TaggedState] do
    regular <- State.get()
    tagged <- TaggedState.get(:cache)

    State.put(regular + 1)
    TaggedState.put(:cache, tagged + 10)

    new_regular <- State.get()
    new_tagged <- TaggedState.get(:cache)

    return(%{regular: new_regular, tagged: new_tagged})
  end

  defcon use_reader_writer_tagged, [Reader, Writer, TaggedState] do
    env <- Reader.ask()
    cache <- TaggedState.get(:cache)

    result <- return(env.multiplier * cache)

    Writer.tell("Computed: #{result}")
    TaggedState.put(:cache, result)
    TaggedState.put(:last_result, result)

    return(result)
  end

  # Nested computations
  defcon increment_cache, [TaggedState] do
    val <- TaggedState.get(:cache)
    TaggedState.put(:cache, val + 1)
    return(val + 1)
  end

  defcon call_increment_three_times, [TaggedState] do
    r1 <- increment_cache()
    r2 <- increment_cache()
    r3 <- increment_cache()
    return([r1, r2, r3])
  end

  defcon update_stats, [TaggedState] do
    count <- TaggedState.get(:count)
    total <- TaggedState.get(:total)

    TaggedState.put(:count, count + 1)
    TaggedState.put(:total, total + count)

    return({count, total})
  end

  defcon call_update_stats_three_times, [TaggedState] do
    s1 <- update_stats()
    s2 <- update_stats()
    s3 <- update_stats()

    final_count <- TaggedState.get(:count)
    final_total <- TaggedState.get(:total)

    return(%{
      steps: [s1, s2, s3],
      final: {final_count, final_total}
    })
  end

  # Tag types
  defcon use_atom_tag, [TaggedState] do
    TaggedState.put(:atom_tag, "value")
    TaggedState.get(:atom_tag)
  end

  defcon use_string_tag, [TaggedState] do
    TaggedState.put("string_tag", "value")
    TaggedState.get("string_tag")
  end

  defcon use_number_tags, [TaggedState] do
    TaggedState.put(1, "first")
    TaggedState.put(2, "second")
    v1 <- TaggedState.get(1)
    v2 <- TaggedState.get(2)
    return({v1, v2})
  end

  defcon use_tuple_tags, [TaggedState] do
    TaggedState.put({:user, 123}, %{name: "Alice"})
    TaggedState.put({:user, 456}, %{name: "Bob"})

    alice <- TaggedState.get({:user, 123})
    bob <- TaggedState.get({:user, 456})

    return({alice, bob})
  end

  defcon trigger_error, [TaggedState] do
    TaggedState.get(:cache)
  end

  # Tests
  describe "basic tagged state operations" do
    test "get and put with single tag" do
      runner =
        Run.with_handlers(
          ts: {TaggedState.Handler, %{cache: 5}}
        )

      outcome = Run.run(get_and_increment_cache(), runner)

      assert outcome.result == %Freyja.OkResult{value: 15}
      assert outcome.outputs.ts == %{cache: 15}
    end

    test "put returns old value" do
      runner =
        Run.with_handlers(
          ts: {TaggedState.Handler, %{counter: 42}}
        )

      outcome = Run.run(put_and_return_old(), runner)

      assert outcome.result == %Freyja.OkResult{value: 42}
      assert outcome.outputs.ts == %{counter: 100}
    end

    test "get returns nil for missing tag" do
      runner =
        Run.with_handlers(
          ts: {TaggedState.Handler, %{}}
        )

      outcome = Run.run(get_missing_tag(), runner)

      assert outcome.result == %Freyja.OkResult{value: nil}
    end
  end

  describe "multiple tagged states" do
    test "manage multiple independent states" do
      runner =
        Run.with_handlers(
          ts: {TaggedState.Handler, %{
            cache: %{},
            config: %{host: "localhost", port: 8080},
            session_id: 100
          }}
        )

      outcome = Run.run(manage_multiple_states(), runner)

      assert outcome.result == %Freyja.OkResult{
        value: %{
          cache: %{new_key: "new_value"},
          config: %{host: "localhost", port: 8080},
          session: 101
        }
      }

      assert outcome.outputs.ts == %{
        cache: %{new_key: "new_value"},
        config: %{host: "localhost", port: 8080},
        session_id: 101
      }
    end

    test "different value types per tag" do
      runner =
        Run.with_handlers(
          ts: {TaggedState.Handler, %{}}
        )

      outcome = Run.run(put_different_types(), runner)

      assert outcome.result == %Freyja.OkResult{value: :ok}
      assert outcome.outputs.ts == %{
        number: 42,
        string: "hello",
        list: [1, 2, 3],
        map: %{a: 1},
        tuple: {:ok, "result"}
      }
    end
  end

  describe "composition with other effects" do
    test "TaggedState with regular State" do
      runner =
        Run.with_handlers(
          s: {State.Handler, 5},
          ts: {TaggedState.Handler, %{cache: 100}}
        )

      outcome = Run.run(use_state_and_tagged_state(), runner)

      assert outcome.result == %Freyja.OkResult{value: %{regular: 6, tagged: 110}}
      assert outcome.outputs.s == 6
      assert outcome.outputs.ts == %{cache: 110}
    end

    test "TaggedState with Reader and Writer" do
      runner =
        Run.with_handlers(
          r: {Reader.Handler, %{multiplier: 3}},
          w: {Writer.Handler, []},
          ts: {TaggedState.Handler, %{cache: 10}}
        )

      outcome = Run.run(use_reader_writer_tagged(), runner)

      assert outcome.result == %Freyja.OkResult{value: 30}
      assert outcome.outputs.w == ["Computed: 30"]
      assert outcome.outputs.ts == %{cache: 30, last_result: 30}
    end
  end

  describe "nested computations" do
    test "nested functions using TaggedState" do
      runner =
        Run.with_handlers(
          ts: {TaggedState.Handler, %{cache: 0}}
        )

      outcome = Run.run(call_increment_three_times(), runner)

      assert outcome.result == %Freyja.OkResult{value: [1, 2, 3]}
      assert outcome.outputs.ts == %{cache: 3}
    end

    test "multiple tags in nested computations" do
      runner =
        Run.with_handlers(
          ts: {TaggedState.Handler, %{count: 0, total: 0}}
        )

      outcome = Run.run(call_update_stats_three_times(), runner)

      assert outcome.result == %Freyja.OkResult{
        value: %{
          steps: [{0, 0}, {1, 0}, {2, 1}],
          final: {3, 3}
        }
      }

      assert outcome.outputs.ts == %{count: 3, total: 3}
    end
  end

  describe "error handling" do
    test "raises ArgumentError if handler state is not a map" do
      runner =
        Run.with_handlers(
          ts: {TaggedState.Handler, "not a map"}
        )

      assert_raise ArgumentError, ~r/TaggedState.Handler state must be a map/, fn ->
        Run.run(trigger_error(), runner)
      end
    end
  end

  describe "tag types" do
    test "supports atom tags" do
      runner = Run.with_handlers(ts: {TaggedState.Handler, %{}})
      outcome = Run.run(use_atom_tag(), runner)

      assert outcome.result == %Freyja.OkResult{value: "value"}
    end

    test "supports string tags" do
      runner = Run.with_handlers(ts: {TaggedState.Handler, %{}})
      outcome = Run.run(use_string_tag(), runner)

      assert outcome.result == %Freyja.OkResult{value: "value"}
    end

    test "supports number tags" do
      runner = Run.with_handlers(ts: {TaggedState.Handler, %{}})
      outcome = Run.run(use_number_tags(), runner)

      assert outcome.result == %Freyja.OkResult{value: {"first", "second"}}
    end

    test "supports tuple tags" do
      runner = Run.with_handlers(ts: {TaggedState.Handler, %{}})
      outcome = Run.run(use_tuple_tags(), runner)

      assert outcome.result == %Freyja.OkResult{
        value: {%{name: "Alice"}, %{name: "Bob"}}
      }
    end
  end
end
