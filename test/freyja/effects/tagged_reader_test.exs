defmodule Freyja.Effects.TaggedReaderTest do
  use ExUnit.Case

  import Freyja.Con

  alias Freyja.Effects.TaggedReader
  alias Freyja.Effects.Reader
  alias Freyja.Effects.State
  alias Freyja.Effects.Writer
  alias Freyja.Run

  # Basic operations
  defcon simple_ask_tagged, [TaggedReader] do
    ask(:database)
  end

  defcon ask_multiple_tags, [TaggedReader] do
    db <- ask(:database)
    api <- ask(:api)
    env <- ask(:environment)
    return(%{db: db, api: api, env: env})
  end

  defcon ask_missing_tag, [TaggedReader] do
    ask(:missing)
  end

  # Read-only verification
  defcon ask_twice_same_tag, [TaggedReader] do
    val1 <- ask(:config)
    val2 <- ask(:config)
    return({val1, val2})
  end

  defcon modify_and_ask_again, [TaggedReader] do
    env1 <- ask(:data)
    # Try to "modify" the environment (won't affect subsequent asks)
    _modified <- return(Map.put(env1, :modified, true))
    env2 <- ask(:data)
    return({env1, env2})
  end

  # Composition with other effects
  defcon reader_state_composition, [TaggedReader, State] do
    multiplier <- ask(:multiplier)
    counter <- State.get()
    result <- return(counter * multiplier)
    _ <- State.put(result)
    return(result)
  end

  defcon reader_writer_composition, [TaggedReader, Writer] do
    db_cfg <- ask(:database)
    api_cfg <- ask(:api)

    _ <- Writer.tell("Accessing database: #{db_cfg.host}")
    _ <- Writer.tell("Accessing API: #{api_cfg.url}")

    return({:configured, db_cfg, api_cfg})
  end

  defcon all_effects_composition, [TaggedReader, State, Writer] do
    multiplier <- ask(:multiplier)
    counter <- State.get()

    result <- return(counter * multiplier)

    _ <- Writer.tell("Multiplying #{counter} by #{multiplier}")
    _ <- State.put(result)
    _ <- Writer.tell("Result: #{result}")

    return(result)
  end

  # Nested computations
  defcon get_db_config, [TaggedReader] do
    ask(:database)
  end

  defcon get_api_config, [TaggedReader] do
    ask(:api)
  end

  defcon nested_config_fetch, [TaggedReader] do
    db <- get_db_config()
    api <- get_api_config()
    return(%{database: db, api: api})
  end

  defcon level3, [TaggedReader] do
    ask(:deep)
  end

  defcon level2, [TaggedReader] do
    level3()
  end

  defcon level1, [TaggedReader] do
    level2()
  end

  # Complex environment structures
  defcon complex_nested_env, [TaggedReader] do
    %{database: %{host: host, port: port}} <- ask(:config)
    %{api: %{base_url: url}} <- ask(:config)
    return("db: #{host}:#{port}, api: #{url}")
  end

  # Tag types
  defcon use_atom_tag, [TaggedReader] do
    ask(:atom_tag)
  end

  defcon use_string_tag, [TaggedReader] do
    ask("string_tag")
  end

  defcon use_number_tag, [TaggedReader] do
    v1 <- ask(1)
    v2 <- ask(2)
    return({v1, v2})
  end

  defcon use_tuple_tag, [TaggedReader] do
    user1 <- ask({:user, 123})
    user2 <- ask({:user, 456})
    return({user1, user2})
  end

  # Comparison with regular Reader
  defcon use_both_readers, [Reader, TaggedReader] do
    # Regular reader - single untagged environment
    regular_env <- Reader.ask()

    # Tagged reader - multiple tagged environments
    db_cfg <- ask(:database)
    api_cfg <- ask(:api)

    return(%{
      regular: regular_env,
      database: db_cfg,
      api: api_cfg
    })
  end

  defcon trigger_error, [TaggedReader] do
    ask(:config)
  end

  # Tests
  describe "basic tagged reader operations" do
    test "simple ask operation" do
      outcome = Run.run(simple_ask_tagged(), [TaggedReader.Handler], %{TaggedReader.Handler => %{database: %{host: "localhost"}}})

      assert outcome.result == %{host: "localhost"}
    end

    test "ask multiple tags" do
      outcome = Run.run(ask_multiple_tags(), [TaggedReader.Handler], %{TaggedReader.Handler => %{
               database: %{host: "db.example.com"},
               api: %{url: "https://api.example.com"},
               environment: :production
             }})

      assert outcome.result == %{
               db: %{host: "db.example.com"},
               api: %{url: "https://api.example.com"},
               env: :production
             }
    end

    test "ask returns nil for missing tag" do
      outcome = Run.run(ask_missing_tag(), [TaggedReader.Handler], %{TaggedReader.Handler => %{}})

      assert outcome.result == nil
    end
  end

  describe "read-only behavior" do
    test "asking twice returns same value" do
      outcome = Run.run(ask_twice_same_tag(), [TaggedReader.Handler], %{TaggedReader.Handler => %{config: %{setting: "value"}}})

      {val1, val2} = outcome.result
      assert val1 == %{setting: "value"}
      assert val2 == %{setting: "value"}
      assert val1 == val2
    end

    test "environment is truly read-only" do
      original = %{value: 42}

      outcome = Run.run(modify_and_ask_again(), [TaggedReader.Handler], %{TaggedReader.Handler => %{data: original}})

      {env1, env2} = outcome.result
      assert env1 == original
      assert env2 == original
      assert env1 == env2
    end
  end

  describe "composition with other effects" do
    test "TaggedReader with State" do
      outcome = Run.run(reader_state_composition(), [TaggedReader.Handler, State.Handler], %{
        TaggedReader.Handler => %{multiplier: 3},
        State.Handler => 5
      })

      assert outcome.result == 15
      assert outcome.outputs[State.Handler] == 15
    end

    test "TaggedReader with Writer" do
      outcome = Run.run(reader_writer_composition(), [TaggedReader.Handler, Writer.Handler], %{
        TaggedReader.Handler => %{
          database: %{host: "db.local"},
          api: %{url: "https://api.local"}
        },
        Writer.Handler => []
      })

      assert outcome.result == {:configured, %{host: "db.local"}, %{url: "https://api.local"}}

      assert outcome.outputs[Writer.Handler] == [
               "Accessing API: https://api.local",
               "Accessing database: db.local"
             ]
    end

    test "TaggedReader with State and Writer" do
      outcome = Run.run(all_effects_composition(), [TaggedReader.Handler, State.Handler, Writer.Handler], %{
        TaggedReader.Handler => %{multiplier: 4},
        State.Handler => 7,
        Writer.Handler => []
      })

      assert outcome.result == 28
      assert outcome.outputs[State.Handler] == 28

      assert outcome.outputs[Writer.Handler] == [
               "Result: 28",
               "Multiplying 7 by 4"
             ]
    end

    test "TaggedReader with regular Reader" do
      outcome = Run.run(use_both_readers(), [Reader.Handler, TaggedReader.Handler], %{
        Reader.Handler => %{global: "config"},
        TaggedReader.Handler => %{
          database: %{host: "db.example.com"},
          api: %{url: "https://api.example.com"}
        }
      })

      assert outcome.result == %{
               regular: %{global: "config"},
               database: %{host: "db.example.com"},
               api: %{url: "https://api.example.com"}
             }
    end
  end

  describe "nested computations" do
    test "nested function calls" do
      outcome = Run.run(nested_config_fetch(), [TaggedReader.Handler], %{
        TaggedReader.Handler => %{
          database: %{host: "nested.db"},
          api: %{url: "https://nested.api"}
        }
      })

      assert outcome.result == %{
               database: %{host: "nested.db"},
               api: %{url: "https://nested.api"}
             }
    end

    test "deep nesting propagates environment" do
      outcome = Run.run(level1(), [TaggedReader.Handler], %{TaggedReader.Handler => %{deep: :deeply_nested_value}})

      assert outcome.result == :deeply_nested_value
    end
  end

  describe "complex environment structures" do
    test "complex nested structure access" do
      config = %{
        database: %{host: "complex.db", port: 5432},
        api: %{base_url: "https://complex.api"}
      }

      outcome = Run.run(complex_nested_env(), [TaggedReader.Handler], %{TaggedReader.Handler => %{config: config}})

      assert outcome.result == "db: complex.db:5432, api: https://complex.api"
    end
  end

  describe "tag types" do
    test "supports atom tags" do
      outcome = Run.run(use_atom_tag(), [TaggedReader.Handler], %{TaggedReader.Handler => %{atom_tag: :atom_value}})

      assert outcome.result == :atom_value
    end

    test "supports string tags" do
      outcome = Run.run(use_string_tag(), [TaggedReader.Handler], %{TaggedReader.Handler => %{"string_tag" => "string_value"}})

      assert outcome.result == "string_value"
    end

    test "supports number tags" do
      outcome = Run.run(use_number_tag(), [TaggedReader.Handler], %{TaggedReader.Handler => %{1 => "first", 2 => "second"}})

      assert outcome.result == {"first", "second"}
    end

    test "supports tuple tags" do
      outcome = Run.run(use_tuple_tag(), [TaggedReader.Handler], %{
        TaggedReader.Handler => %{
          {:user, 123} => %{name: "Alice"},
          {:user, 456} => %{name: "Bob"}
        }
      })

      assert outcome.result == {%{name: "Alice"}, %{name: "Bob"}}
    end
  end

  describe "error handling" do
    test "raises ArgumentError if handler state is not a map" do
      assert_raise ArgumentError, ~r/TaggedReader.Handler state must be a map/, fn ->
        Run.run(trigger_error(), [TaggedReader.Handler], %{TaggedReader.Handler => "not a map"})
      end
    end
  end
end
