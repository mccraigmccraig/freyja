defmodule Freyja.Effects.TaggedReaderTest do
  use ExUnit.Case

  use Freyja.Syntax

  alias Freyja.Effects.Lift
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

  defcon get_all_envs, [TaggedReader] do
    ask_all()
  end

  defcon compare_all_and_individual, [TaggedReader] do
    all_envs <- ask_all()
    db <- ask(:database)
    api <- ask(:api)

    return(%{
      all: all_envs,
      db_from_all: Map.get(all_envs, :database),
      api_from_all: Map.get(all_envs, :api),
      db_individual: db,
      api_individual: api
    })
  end

  defcon get_all_empty, [TaggedReader] do
    ask_all()
  end

  defcon process_all_tags, [TaggedReader] do
    all <- ask_all()

    result <-
      return(
        all
        |> Map.keys()
        |> Enum.sort()
        |> Enum.map(fn key -> {key, Map.get(all, key)} end)
      )

    return(result)
  end

  # Tests
  describe "basic tagged reader operations" do
    test "simple ask operation" do
      outcome =
        simple_ask_tagged()
        |> TaggedReader.Handler.run(%{database: %{host: "localhost"}})
        |> Run.run()

      assert outcome.result == %{host: "localhost"}
    end

    test "ask multiple tags" do
      outcome =
        ask_multiple_tags()
        |> TaggedReader.Handler.run(%{
          database: %{host: "db.example.com"},
          api: %{url: "https://api.example.com"},
          environment: :production
        })
        |> Run.run()

      assert outcome.result == %{
               db: %{host: "db.example.com"},
               api: %{url: "https://api.example.com"},
               env: :production
             }
    end

    test "ask returns nil for missing tag" do
      outcome =
        ask_missing_tag()
        |> TaggedReader.Handler.run(%{})
        |> Run.run()

      assert outcome.result == nil
    end

    test "ask_all returns entire environment map" do
      state = %{
        database: %{host: "db.example.com", port: 5432},
        api: %{url: "https://api.example.com", timeout: 30},
        environment: :production
      }

      outcome =
        get_all_envs()
        |> TaggedReader.Handler.run(state)
        |> Run.run()

      assert outcome.result == state
    end

    test "ask_all with individual asks" do
      state = %{
        database: %{host: "db.local"},
        api: %{url: "https://api.local"}
      }

      outcome =
        compare_all_and_individual()
        |> TaggedReader.Handler.run(state)
        |> Run.run()

      result = outcome.result
      assert result.all == state
      assert result.db_from_all == result.db_individual
      assert result.api_from_all == result.api_individual
    end

    test "ask_all returns empty map when no environments" do
      outcome =
        get_all_empty()
        |> TaggedReader.Handler.run(%{})
        |> Run.run()

      assert outcome.result == %{}
    end

    test "ask_all with computation using all tags" do
      state = %{
        database: %{host: "db"},
        api: %{url: "api"},
        cache: %{ttl: 300}
      }

      outcome =
        process_all_tags()
        |> TaggedReader.Handler.run(state)
        |> Run.run()

      assert outcome.result == [
               {:api, %{url: "api"}},
               {:cache, %{ttl: 300}},
               {:database, %{host: "db"}}
             ]
    end
  end

  describe "read-only behavior" do
    test "asking twice returns same value" do
      outcome =
        ask_twice_same_tag()
        |> TaggedReader.Handler.run(%{config: %{setting: "value"}})
        |> Run.run()

      {val1, val2} = outcome.result
      assert val1 == %{setting: "value"}
      assert val2 == %{setting: "value"}
      assert val1 == val2
    end

    test "environment is truly read-only" do
      original = %{value: 42}

      outcome =
        modify_and_ask_again()
        |> TaggedReader.Handler.run(%{data: original})
        |> Run.run()

      {env1, env2} = outcome.result
      assert env1 == original
      assert env2 == original
      assert env1 == env2
    end
  end

  describe "composition with other effects" do
    test "TaggedReader with State" do
      outcome =
        reader_state_composition()
        |> TaggedReader.Handler.run(%{multiplier: 3})
        |> State.Handler.run(5)
        |> Run.run()

      assert outcome.result == 15
      assert outcome.outputs[State.Handler] == 15
    end

    test "TaggedReader with Writer" do
      outcome =
        reader_writer_composition()
        |> TaggedReader.Handler.run(%{
          database: %{host: "db.local"},
          api: %{url: "https://api.local"}
        })
        |> Writer.Handler.run([])
        |> Run.run()

      assert outcome.result == {:configured, %{host: "db.local"}, %{url: "https://api.local"}}

      assert outcome.outputs[Writer.Handler] == [
               "Accessing API: https://api.local",
               "Accessing database: db.local"
             ]
    end

    test "TaggedReader with State and Writer" do
      outcome =
        all_effects_composition()
        |> TaggedReader.Handler.run(%{multiplier: 4})
        |> State.Handler.run(7)
        |> Writer.Handler.run([])
        |> Run.run()

      assert outcome.result == 28
      assert outcome.outputs[State.Handler] == 28

      assert outcome.outputs[Writer.Handler] == [
               "Result: 28",
               "Multiplying 7 by 4"
             ]
    end

    test "TaggedReader with regular Reader" do
      outcome =
        use_both_readers()
        |> Reader.Handler.run(%{global: "config"})
        |> TaggedReader.Handler.run(%{
          database: %{host: "db.example.com"},
          api: %{url: "https://api.example.com"}
        })
        |> Run.run()

      assert outcome.result == %{
               regular: %{global: "config"},
               database: %{host: "db.example.com"},
               api: %{url: "https://api.example.com"}
             }
    end
  end

  describe "nested computations" do
    test "nested function calls" do
      outcome =
        nested_config_fetch()
        |> TaggedReader.Handler.run(%{
          database: %{host: "nested.db"},
          api: %{url: "https://nested.api"}
        })
        |> Run.run()

      assert outcome.result == %{
               database: %{host: "nested.db"},
               api: %{url: "https://nested.api"}
             }
    end

    test "deep nesting propagates environment" do
      outcome =
        level1()
        |> TaggedReader.Handler.run(%{deep: :deeply_nested_value})
        |> Run.run()

      assert outcome.result == :deeply_nested_value
    end
  end

  describe "complex environment structures" do
    test "complex nested structure access" do
      config = %{
        database: %{host: "complex.db", port: 5432},
        api: %{base_url: "https://complex.api"}
      }

      outcome =
        complex_nested_env()
        |> TaggedReader.Handler.run(%{config: config})
        |> Run.run()

      assert outcome.result == "db: complex.db:5432, api: https://complex.api"
    end
  end

  describe "tag types" do
    test "supports atom tags" do
      outcome =
        use_atom_tag()
        |> TaggedReader.Handler.run(%{atom_tag: :atom_value})
        |> Run.run()

      assert outcome.result == :atom_value
    end

    test "supports string tags" do
      outcome =
        use_string_tag()
        |> TaggedReader.Handler.run(%{"string_tag" => "string_value"})
        |> Run.run()

      assert outcome.result == "string_value"
    end

    test "supports number tags" do
      outcome =
        use_number_tag()
        |> TaggedReader.Handler.run(%{1 => "first", 2 => "second"})
        |> Run.run()

      assert outcome.result == {"first", "second"}
    end

    test "supports tuple tags" do
      outcome =
        use_tuple_tag()
        |> TaggedReader.Handler.run(%{
          {:user, 123} => %{name: "Alice"},
          {:user, 456} => %{name: "Bob"}
        })
        |> Run.run()

      assert outcome.result == {%{name: "Alice"}, %{name: "Bob"}}
    end
  end

  describe "error handling" do
    test "raises ArgumentError if handler state is not a map" do
      assert_raise ArgumentError, ~r/TaggedReader.Handler state must be a map/, fn ->
        trigger_error()
        |> TaggedReader.Handler.run("not a map")
        |> Run.run()
      end
    end
  end

  describe "TaggedReader.Local higher-order operation" do
    test "basic local modification for single tag" do
      computation =
        hefty do
          base_db <- TaggedReader.ask(:database)
          base_api <- TaggedReader.ask(:api)

          result <-
            TaggedReader.local(
              :database,
              fn config -> %{config | port: 5433} end,
              hefty do
                db <- TaggedReader.ask(:database)
                api <- TaggedReader.ask(:api)
                return({db.port, api.url})
              end
            )

          final_db <- TaggedReader.ask(:database)
          final_api <- TaggedReader.ask(:api)
          return({base_db.port, base_api.url, result, final_db.port, final_api.url})
        end

      outcome =
        computation
        |> TaggedReader.Algebra.run()
        |> Lift.Algebra.run()
        |> TaggedReader.Handler.run(%{
          database: %{host: "db.local", port: 5432},
          api: %{url: "https://api.local"}
        })
        |> Run.run()

      # Base db port: 5432, api unchanged, inside local db port: 5433, after local db port: 5432 again
      assert outcome.result ==
               {5432, "https://api.local", {5433, "https://api.local"}, 5432, "https://api.local"}
    end

    test "nested local scopes for same tag" do
      computation =
        hefty do
          result <-
            TaggedReader.local(
              :config,
              fn val -> val + 10 end,
              hefty do
                level1 <- TaggedReader.ask(:config)

                result <-
                  TaggedReader.local(
                    :config,
                    fn val -> val + 10 end,
                    hefty do
                      level2 <- TaggedReader.ask(:config)
                      return(level2)
                    end
                  )

                return({level1, result})
              end
            )

          base <- TaggedReader.ask(:config)
          return({base, result})
        end

      outcome =
        computation
        |> TaggedReader.Algebra.run()
        |> Lift.Algebra.run()
        |> TaggedReader.Handler.run(%{config: 5})
        |> Run.run()

      # Base: 5, first local: 15, second local: 25
      assert outcome.result == {5, {15, 25}}
    end

    test "local for different tags independently" do
      computation =
        hefty do
          result1 <-
            TaggedReader.local(
              :db,
              fn port -> port + 1 end,
              hefty do
                TaggedReader.ask(:db)
              end
            )

          result2 <-
            TaggedReader.local(
              :api,
              fn timeout -> timeout * 2 end,
              hefty do
                TaggedReader.ask(:api)
              end
            )

          db <- TaggedReader.ask(:db)
          api <- TaggedReader.ask(:api)
          return({result1, result2, db, api})
        end

      outcome =
        computation
        |> TaggedReader.Algebra.run()
        |> Lift.Algebra.run()
        |> TaggedReader.Handler.run(%{db: 5432, api: 30})
        |> Run.run()

      # result1: 5433 (5432+1), result2: 60 (30*2), final: 5432, 30
      assert outcome.result == {5433, 60, 5432, 30}
    end

    test "local with state effects" do
      computation =
        hefty do
          result <-
            TaggedReader.local(
              :multiplier,
              fn mult -> mult * 2 end,
              hefty do
                mult <- TaggedReader.ask(:multiplier)
                counter <- State.get()
                _unit <- State.put(counter * mult)
                new_counter <- State.get()
                return(new_counter)
              end
            )

          final_mult <- TaggedReader.ask(:multiplier)
          final_counter <- State.get()
          return({result, final_mult, final_counter})
        end

      outcome =
        computation
        |> TaggedReader.Algebra.run()
        |> Lift.Algebra.run()
        |> TaggedReader.Handler.run(%{multiplier: 3})
        |> State.Handler.run(5)
        |> Run.run()

      # Inside local: multiplier is 6 (3*2), counter becomes 30 (5*6)
      # Outside local: multiplier is 3, counter is 30 (state persists)
      assert outcome.result == {30, 3, 30}
      assert outcome.outputs[State.Handler] == 30
    end
  end

  describe "TaggedReader.LocalAll higher-order operation" do
    test "basic local_all modification" do
      computation =
        hefty do
          base_db <- TaggedReader.ask(:database)
          base_api <- TaggedReader.ask(:api)

          result <-
            TaggedReader.local_all(
              fn envs ->
                envs
                |> Map.update(:database, %{}, fn db -> %{db | port: 5433} end)
                |> Map.update(:api, %{}, fn api -> %{api | timeout: 60} end)
              end,
              hefty do
                db <- TaggedReader.ask(:database)
                api <- TaggedReader.ask(:api)
                return({db.port, api.timeout})
              end
            )

          final_db <- TaggedReader.ask(:database)
          final_api <- TaggedReader.ask(:api)
          return({base_db.port, base_api.timeout, result, final_db.port, final_api.timeout})
        end

      outcome =
        computation
        |> TaggedReader.Algebra.run()
        |> Lift.Algebra.run()
        |> TaggedReader.Handler.run(%{
          database: %{host: "db.local", port: 5432},
          api: %{url: "https://api.local", timeout: 30}
        })
        |> Run.run()

      # Base: 5432, 30; inside local_all: 5433, 60; after: 5432, 30
      assert outcome.result == {5432, 30, {5433, 60}, 5432, 30}
    end

    test "local_all with map transformation" do
      computation =
        hefty do
          result <-
            TaggedReader.local_all(
              fn envs ->
                # Double all numeric values
                Map.new(envs, fn {k, v} -> {k, v * 2} end)
              end,
              hefty do
                a <- TaggedReader.ask(:a)
                b <- TaggedReader.ask(:b)
                c <- TaggedReader.ask(:c)
                return(a + b + c)
              end
            )

          a <- TaggedReader.ask(:a)
          b <- TaggedReader.ask(:b)
          return({result, a + b})
        end

      outcome =
        computation
        |> TaggedReader.Algebra.run()
        |> Lift.Algebra.run()
        |> TaggedReader.Handler.run(%{a: 1, b: 2, c: 3})
        |> Run.run()

      # Inside local_all: 2+4+6=12, outside: 1+2=3
      assert outcome.result == {12, 3}
    end

    test "nested local_all scopes" do
      computation =
        hefty do
          result <-
            TaggedReader.local_all(
              fn envs -> Map.new(envs, fn {k, v} -> {k, v + 10} end) end,
              hefty do
                level1 <- TaggedReader.ask(:value)

                result <-
                  TaggedReader.local_all(
                    fn envs -> Map.new(envs, fn {k, v} -> {k, v + 10} end) end,
                    hefty do
                      level2 <- TaggedReader.ask(:value)
                      return(level2)
                    end
                  )

                return({level1, result})
              end
            )

          base <- TaggedReader.ask(:value)
          return({base, result})
        end

      outcome =
        computation
        |> TaggedReader.Algebra.run()
        |> Lift.Algebra.run()
        |> TaggedReader.Handler.run(%{value: 5})
        |> Run.run()

      # Base: 5, first local_all: 15, second local_all: 25
      assert outcome.result == {5, {15, 25}}
    end

    test "local_all with coroutine yield" do
      alias Freyja.Effects.Coroutine

      computation =
        hefty do
          result <-
            TaggedReader.local_all(
              fn envs -> Map.new(envs, fn {k, v} -> {k, v * 2} end) end,
              hefty do
                before <- TaggedReader.ask(:value)
                resume_val <- Coroutine.yield({:yielded, before})
                after_resume <- TaggedReader.ask(:value)
                return({before, resume_val, after_resume})
              end
            )

          final <- TaggedReader.ask(:value)
          return({result, final})
        end

      # Initial run - suspends inside local_all scope
      builder =
        computation
        |> TaggedReader.Algebra.run()
        |> Lift.Algebra.run()
        |> TaggedReader.Handler.run(%{value: 10})
        |> Coroutine.Handler.run()

      outcome = builder |> Run.run()

      # Should suspend with modified value (10*2=20)
      assert {:suspend, {:yielded, 20}, _continuation} = outcome.result

      # Resume the computation
      outcome2 = Run.resume(builder, outcome, :resumed)

      # After resume, local_all scope still applies, then restores
      # Result: {{before, resume_val, after_resume}, final}
      assert {:done, {{20, :resumed, 20}, 10}} = outcome2.result
    end

    test "local_all with ask_all" do
      computation =
        hefty do
          base_all <- TaggedReader.ask_all()

          result <-
            TaggedReader.local_all(
              fn envs ->
                Map.new(envs, fn
                  {:database, db} -> {:database, %{db | port: db.port + 1}}
                  {:api, api} -> {:api, %{api | timeout: api.timeout * 2}}
                  {k, v} -> {k, v}
                end)
              end,
              hefty do
                modified_all <- TaggedReader.ask_all()
                db <- TaggedReader.ask(:database)
                api <- TaggedReader.ask(:api)
                return({modified_all, db, api})
              end
            )

          final_all <- TaggedReader.ask_all()
          return({base_all, result, final_all})
        end

      state = %{
        database: %{host: "db.local", port: 5432},
        api: %{url: "https://api.local", timeout: 30}
      }

      outcome =
        computation
        |> TaggedReader.Algebra.run()
        |> Lift.Algebra.run()
        |> TaggedReader.Handler.run(state)
        |> Run.run()

      {base_all, {modified_all, db, api}, final_all} = outcome.result

      # Base state unchanged
      assert base_all == state
      assert final_all == state

      # Modified state inside local_all
      assert modified_all == %{
               database: %{host: "db.local", port: 5433},
               api: %{url: "https://api.local", timeout: 60}
             }

      assert db == %{host: "db.local", port: 5433}
      assert api == %{url: "https://api.local", timeout: 60}
    end
  end
end
