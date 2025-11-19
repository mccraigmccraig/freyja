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
      runner =
        Run.with_handlers(
          tr: {TaggedReader.Handler, %{database: %{host: "localhost"}}}
        )

      outcome = Run.run(simple_ask_tagged(), runner)

      assert outcome.result == %{host: "localhost"}
    end

    test "ask multiple tags" do
      runner =
        Run.with_handlers(
          tr: {TaggedReader.Handler, %{
            database: %{host: "db.example.com"},
            api: %{url: "https://api.example.com"},
            environment: :production
          }}
        )

      outcome = Run.run(ask_multiple_tags(), runner)

      assert outcome.result == %{
          db: %{host: "db.example.com"},
          api: %{url: "https://api.example.com"},
          env: :production
        }
    end

    test "ask returns nil for missing tag" do
      runner =
        Run.with_handlers(
          tr: {TaggedReader.Handler, %{}}
        )

      outcome = Run.run(ask_missing_tag(), runner)

      assert outcome.result == nil
    end
  end

  describe "read-only behavior" do
    test "asking twice returns same value" do
      runner =
        Run.with_handlers(
          tr: {TaggedReader.Handler, %{config: %{setting: "value"}}}
        )

      outcome = Run.run(ask_twice_same_tag(), runner)

      {val1, val2} = outcome.result
      assert val1 == %{setting: "value"}
      assert val2 == %{setting: "value"}
      assert val1 == val2
    end

    test "environment is truly read-only" do
      original = %{value: 42}
      runner =
        Run.with_handlers(
          tr: {TaggedReader.Handler, %{data: original}}
        )

      outcome = Run.run(modify_and_ask_again(), runner)

      {env1, env2} = outcome.result
      assert env1 == original
      assert env2 == original
      assert env1 == env2
    end
  end

  describe "composition with other effects" do
    test "TaggedReader with State" do
      runner =
        Run.with_handlers(
          tr: {TaggedReader.Handler, %{multiplier: 3}},
          s: {State.Handler, 5}
        )

      outcome = Run.run(reader_state_composition(), runner)

      assert outcome.result == 15
      assert outcome.outputs.s == 15
    end

    test "TaggedReader with Writer" do
      runner =
        Run.with_handlers(
          tr: {TaggedReader.Handler, %{
            database: %{host: "db.local"},
            api: %{url: "https://api.local"}
          }},
          w: {Writer.Handler, []}
        )

      outcome = Run.run(reader_writer_composition(), runner)

      assert outcome.result == {:configured, %{host: "db.local"}, %{url: "https://api.local"}}
      assert outcome.outputs.w == [
        "Accessing API: https://api.local",
        "Accessing database: db.local"
      ]
    end

    test "TaggedReader with State and Writer" do
      runner =
        Run.with_handlers(
          tr: {TaggedReader.Handler, %{multiplier: 4}},
          s: {State.Handler, 7},
          w: {Writer.Handler, []}
        )

      outcome = Run.run(all_effects_composition(), runner)

      assert outcome.result == 28
      assert outcome.outputs.s == 28
      assert outcome.outputs.w == [
        "Result: 28",
        "Multiplying 7 by 4"
      ]
    end

    test "TaggedReader with regular Reader" do
      runner =
        Run.with_handlers(
          r: {Reader.Handler, %{global: "config"}},
          tr: {TaggedReader.Handler, %{
            database: %{host: "db.example.com"},
            api: %{url: "https://api.example.com"}
          }}
        )

      outcome = Run.run(use_both_readers(), runner)

      assert outcome.result == %{
          regular: %{global: "config"},
          database: %{host: "db.example.com"},
          api: %{url: "https://api.example.com"}
        }
    end
  end

  describe "nested computations" do
    test "nested function calls" do
      runner =
        Run.with_handlers(
          tr: {TaggedReader.Handler, %{
            database: %{host: "nested.db"},
            api: %{url: "https://nested.api"}
          }}
        )

      outcome = Run.run(nested_config_fetch(), runner)

      assert outcome.result == %{
          database: %{host: "nested.db"},
          api: %{url: "https://nested.api"}
        }
    end

    test "deep nesting propagates environment" do
      runner =
        Run.with_handlers(
          tr: {TaggedReader.Handler, %{deep: :deeply_nested_value}}
        )

      outcome = Run.run(level1(), runner)

      assert outcome.result == :deeply_nested_value
    end
  end

  describe "complex environment structures" do
    test "complex nested structure access" do
      config = %{
        database: %{host: "complex.db", port: 5432},
        api: %{base_url: "https://complex.api"}
      }

      runner =
        Run.with_handlers(
          tr: {TaggedReader.Handler, %{config: config}}
        )

      outcome = Run.run(complex_nested_env(), runner)

      assert outcome.result == "db: complex.db:5432, api: https://complex.api"
    end
  end

  describe "tag types" do
    test "supports atom tags" do
      runner = Run.with_handlers(tr: {TaggedReader.Handler, %{atom_tag: :atom_value}})
      outcome = Run.run(use_atom_tag(), runner)

      assert outcome.result == :atom_value
    end

    test "supports string tags" do
      runner = Run.with_handlers(tr: {TaggedReader.Handler, %{"string_tag" => "string_value"}})
      outcome = Run.run(use_string_tag(), runner)

      assert outcome.result == "string_value"
    end

    test "supports number tags" do
      runner = Run.with_handlers(tr: {TaggedReader.Handler, %{1 => "first", 2 => "second"}})
      outcome = Run.run(use_number_tag(), runner)

      assert outcome.result == {"first", "second"}
    end

    test "supports tuple tags" do
      runner = Run.with_handlers(tr: {TaggedReader.Handler, %{
        {:user, 123} => %{name: "Alice"},
        {:user, 456} => %{name: "Bob"}
      }})
      outcome = Run.run(use_tuple_tag(), runner)

      assert outcome.result == {%{name: "Alice"}, %{name: "Bob"}}
    end
  end

  describe "error handling" do
    test "raises ArgumentError if handler state is not a map" do
      runner =
        Run.with_handlers(
          tr: {TaggedReader.Handler, "not a map"}
        )

      assert_raise ArgumentError, ~r/TaggedReader.Handler state must be a map/, fn ->
        Run.run(trigger_error(), runner)
      end
    end
  end
end
