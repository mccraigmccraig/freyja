defmodule Freyja.Effects.TaggedStateTest do
  use ExUnit.Case

  import Freyja.Freer.FreerBlock

  alias Freyja.Effects.TaggedState
  alias Freyja.Effects.State
  alias Freyja.Effects.Reader
  alias Freyja.Effects.Writer
  alias Freyja.Run

  # Basic operations
  defcon get_and_increment_cache, [TaggedState] do
    val <- get(:cache)
    _ <- put(:cache, val + 10)
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
    _ <- TaggedState.put(:cache, Map.put(cache, :new_key, "new_value"))
    _ <- TaggedState.put(:session_id, session + 1)

    # Read updated values
    new_cache <- TaggedState.get(:cache)
    new_session <- TaggedState.get(:session_id)

    return(%{cache: new_cache, config: config, session: new_session})
  end

  defcon put_different_types, [TaggedState] do
    _ <- TaggedState.put(:number, 42)
    _ <- TaggedState.put(:string, "hello")
    _ <- TaggedState.put(:list, [1, 2, 3])
    _ <- TaggedState.put(:map, %{a: 1})
    _ <- TaggedState.put(:tuple, {:ok, "result"})
    return(:ok)
  end

  # Composition with other effects
  defcon use_state_and_tagged_state, [State, TaggedState] do
    regular <- State.get()
    tagged <- TaggedState.get(:cache)

    _ <- State.put(regular + 1)
    _ <- TaggedState.put(:cache, tagged + 10)

    new_regular <- State.get()
    new_tagged <- TaggedState.get(:cache)

    return(%{regular: new_regular, tagged: new_tagged})
  end

  defcon use_reader_writer_tagged, [Reader, Writer, TaggedState] do
    env <- Reader.ask()
    cache <- TaggedState.get(:cache)

    result <- return(env.multiplier * cache)

    _ <- Writer.tell("Computed: #{result}")
    _ <- TaggedState.put(:cache, result)
    _ <- TaggedState.put(:last_result, result)

    return(result)
  end

  # Nested computations
  defcon increment_cache, [TaggedState] do
    val <- TaggedState.get(:cache)
    _ <- TaggedState.put(:cache, val + 1)
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

    _ <- TaggedState.put(:count, count + 1)
    _ <- TaggedState.put(:total, total + count)

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
    _ <- TaggedState.put(:atom_tag, "value")
    TaggedState.get(:atom_tag)
  end

  defcon use_string_tag, [TaggedState] do
    _ <- TaggedState.put("string_tag", "value")
    TaggedState.get("string_tag")
  end

  defcon use_number_tags, [TaggedState] do
    _ <- TaggedState.put(1, "first")
    _ <- TaggedState.put(2, "second")
    v1 <- TaggedState.get(1)
    v2 <- TaggedState.get(2)
    return({v1, v2})
  end

  defcon use_tuple_tags, [TaggedState] do
    _ <- TaggedState.put({:user, 123}, %{name: "Alice"})
    _ <- TaggedState.put({:user, 456}, %{name: "Bob"})

    alice <- TaggedState.get({:user, 123})
    bob <- TaggedState.get({:user, 456})

    return({alice, bob})
  end

  defcon trigger_error, [TaggedState] do
    TaggedState.get(:cache)
  end

  # Update operations
  defcon update_counter, [TaggedState] do
    old_val <- TaggedState.update(:counter, fn c -> c + 1 end)
    new_val <- TaggedState.get(:counter)
    return({old_val, new_val})
  end

  defcon update_with_map_function, [TaggedState] do
    _ <- TaggedState.update(:cache, fn cache -> Map.put(cache, :updated, true) end)
    TaggedState.get(:cache)
  end

  defcon update_multiple_tags, [TaggedState] do
    _ <- TaggedState.update(:count, fn c -> c + 1 end)
    _ <- TaggedState.update(:total, fn t -> t + 10 end)
    _ <- TaggedState.update(:count, fn c -> c * 2 end)

    count <- TaggedState.get(:count)
    total <- TaggedState.get(:total)

    return({count, total})
  end

  defcon update_missing_tag, [TaggedState] do
    # Update should work even if tag doesn't exist (nil case)
    old_val <- TaggedState.update(:missing, fn val -> (val || 0) + 1 end)
    new_val <- TaggedState.get(:missing)
    return({old_val, new_val})
  end

  defcon increment_nested, [TaggedState] do
    _ <- TaggedState.update(:counter, fn c -> c + 1 end)
    TaggedState.get(:counter)
  end

  defcon call_increment_nested_three_times, [TaggedState] do
    r1 <- increment_nested()
    r2 <- increment_nested()
    r3 <- increment_nested()
    return([r1, r2, r3])
  end

  # Tests
  describe "basic tagged state operations" do
    test "get and put with single tag" do
      outcome =
        Run.run(get_and_increment_cache(), [TaggedState.Handler], %{
          TaggedState.Handler => %{cache: 5}
        })

      assert outcome.result == 15
      assert outcome.outputs[TaggedState.Handler] == %{cache: 15}
    end

    test "put returns old value" do
      outcome =
        Run.run(put_and_return_old(), [TaggedState.Handler], %{
          TaggedState.Handler => %{counter: 42}
        })

      assert outcome.result == 42
      assert outcome.outputs[TaggedState.Handler] == %{counter: 100}
    end

    test "get returns nil for missing tag" do
      outcome = Run.run(get_missing_tag(), [TaggedState.Handler], %{TaggedState.Handler => %{}})

      assert outcome.result == nil
    end
  end

  describe "multiple tagged states" do
    test "manage multiple independent states" do
      outcome =
        Run.run(manage_multiple_states(), [TaggedState.Handler], %{
          TaggedState.Handler => %{
            cache: %{},
            config: %{host: "localhost", port: 8080},
            session_id: 100
          }
        })

      assert outcome.result == %{
               cache: %{new_key: "new_value"},
               config: %{host: "localhost", port: 8080},
               session: 101
             }

      assert outcome.outputs[TaggedState.Handler] == %{
               cache: %{new_key: "new_value"},
               config: %{host: "localhost", port: 8080},
               session_id: 101
             }
    end

    test "different value types per tag" do
      outcome =
        Run.run(put_different_types(), [TaggedState.Handler], %{TaggedState.Handler => %{}})

      assert outcome.result == :ok

      assert outcome.outputs[TaggedState.Handler] == %{
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
      outcome =
        Run.run(use_state_and_tagged_state(), [State.Handler, TaggedState.Handler], %{
          State.Handler => 5,
          TaggedState.Handler => %{cache: 100}
        })

      assert outcome.result == %{regular: 6, tagged: 110}
      assert outcome.outputs[State.Handler] == 6
      assert outcome.outputs[TaggedState.Handler] == %{cache: 110}
    end

    test "TaggedState with Reader and Writer" do
      outcome =
        Run.run(
          use_reader_writer_tagged(),
          [Reader.Handler, Writer.Handler, TaggedState.Handler],
          %{
            Reader.Handler => %{multiplier: 3},
            Writer.Handler => [],
            TaggedState.Handler => %{cache: 10}
          }
        )

      assert outcome.result == 30
      assert outcome.outputs[Writer.Handler] == ["Computed: 30"]
      assert outcome.outputs[TaggedState.Handler] == %{cache: 30, last_result: 30}
    end
  end

  describe "nested computations" do
    test "nested functions using TaggedState" do
      outcome =
        Run.run(call_increment_three_times(), [TaggedState.Handler], %{
          TaggedState.Handler => %{cache: 0}
        })

      assert outcome.result == [1, 2, 3]
      assert outcome.outputs[TaggedState.Handler] == %{cache: 3}
    end

    test "multiple tags in nested computations" do
      outcome =
        Run.run(call_update_stats_three_times(), [TaggedState.Handler], %{
          TaggedState.Handler => %{count: 0, total: 0}
        })

      assert outcome.result == %{
               steps: [{0, 0}, {1, 0}, {2, 1}],
               final: {3, 3}
             }

      assert outcome.outputs[TaggedState.Handler] == %{count: 3, total: 3}
    end
  end

  describe "error handling" do
    test "raises ArgumentError if handler state is not a map" do
      assert_raise ArgumentError, ~r/TaggedState.Handler state must be a map/, fn ->
        Run.run(trigger_error(), [TaggedState.Handler], %{TaggedState.Handler => "not a map"})
      end
    end
  end

  describe "tag types" do
    test "supports atom tags" do
      outcome = Run.run(use_atom_tag(), [TaggedState.Handler], %{TaggedState.Handler => %{}})

      assert outcome.result == "value"
    end

    test "supports string tags" do
      outcome = Run.run(use_string_tag(), [TaggedState.Handler], %{TaggedState.Handler => %{}})

      assert outcome.result == "value"
    end

    test "supports number tags" do
      outcome = Run.run(use_number_tags(), [TaggedState.Handler], %{TaggedState.Handler => %{}})

      assert outcome.result == {"first", "second"}
    end

    test "supports tuple tags" do
      outcome = Run.run(use_tuple_tags(), [TaggedState.Handler], %{TaggedState.Handler => %{}})

      assert outcome.result == {%{name: "Alice"}, %{name: "Bob"}}
    end
  end

  describe "update operation" do
    test "updates a counter and returns old value" do
      outcome =
        Run.run(update_counter(), [TaggedState.Handler], %{TaggedState.Handler => %{counter: 5}})

      assert outcome.result == {5, 6}
      assert outcome.outputs[TaggedState.Handler] == %{counter: 6}
    end

    test "updates with map function" do
      outcome =
        Run.run(update_with_map_function(), [TaggedState.Handler], %{
          TaggedState.Handler => %{cache: %{existing: "value"}}
        })

      assert outcome.result == %{existing: "value", updated: true}
      assert outcome.outputs[TaggedState.Handler] == %{cache: %{existing: "value", updated: true}}
    end

    test "updates multiple tags" do
      outcome =
        Run.run(update_multiple_tags(), [TaggedState.Handler], %{
          TaggedState.Handler => %{count: 1, total: 0}
        })

      # count: 1 -> 2 (+ 1) -> 4 (* 2)
      # total: 0 -> 10 (+ 10)
      assert outcome.result == {4, 10}
      assert outcome.outputs[TaggedState.Handler] == %{count: 4, total: 10}
    end

    test "updates missing tag (nil case)" do
      outcome =
        Run.run(update_missing_tag(), [TaggedState.Handler], %{TaggedState.Handler => %{}})

      assert outcome.result == {nil, 1}
      assert outcome.outputs[TaggedState.Handler] == %{missing: 1}
    end

    test "nested update computations" do
      outcome =
        Run.run(call_increment_nested_three_times(), [TaggedState.Handler], %{
          TaggedState.Handler => %{counter: 0}
        })

      assert outcome.result == [1, 2, 3]
      assert outcome.outputs[TaggedState.Handler] == %{counter: 3}
    end
  end
end
