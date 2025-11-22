defmodule Freyja.Effects.ReaderTest do
  use ExUnit.Case

  use Freyja.Syntax

  alias Freyja.Effects.Lift
  alias Freyja.Effects.Reader
  alias Freyja.Effects.State
  alias Freyja.Run

  defmodule ReaderExamples do
    defcon simple_ask, [Reader] do
      env <- ask()
      return(env)
    end

    defcon nested_ask, [Reader] do
      env1 <- ask()
      env2 <- ask()
      return({env1, env2})
    end

    defcon ask_map, [Reader] do
      %{host: host, port: port} <- ask()
      return("#{host}:#{port}")
    end

    defcon ask_atom, [Reader] do
      env <- ask()
      return({:got, env})
    end

    defcon ask_string, [Reader] do
      name <- ask()
      return("Hello, #{name}!")
    end

    defcon reader_with_state, [Reader, State] do
      multiplier <- ask()
      counter <- get()
      new_value <- return(counter * multiplier)
      _ <- put(new_value)
      return(new_value)
    end

    defcon get_config, [Reader] do
      ask()
    end

    defcon use_config, [Reader] do
      config <- get_config()
      return({:using, config})
    end

    defcon read_only_env, [Reader] do
      env1 <- ask()
      # Even if we try to "modify" the environment in our computation,
      # subsequent asks should return the original environment
      _modified <- return(Map.put(env1, :modified, true))
      env2 <- ask()
      return({env1, env2})
    end

    defcon fetch_db_config, [Reader] do
      %{database: db_config} <- ask()
      return(db_config)
    end

    defcon fetch_api_config, [Reader] do
      %{api: api_config} <- ask()
      return(api_config)
    end

    defcon complex_nested, [Reader] do
      db <- fetch_db_config()
      api <- fetch_api_config()
      return(%{db: db, api: api})
    end

    defcon level3, [Reader] do
      ask()
    end

    defcon level2, [Reader] do
      level3()
    end

    defcon level1, [Reader] do
      level2()
    end
  end

  describe "Reader effect" do
    test "simple ask operation" do
      outcome =
        ReaderExamples.simple_ask()
        |> Reader.Handler.run(%{config: "test"})
        |> Run.run()

      assert outcome.result == %{config: "test"}
    end

    test "nested ask calls return same environment" do
      outcome =
        ReaderExamples.nested_ask()
        |> Reader.Handler.run(:test_env)
        |> Run.run()

      assert outcome.result == {:test_env, :test_env}
    end

    test "ask with different environment types - map" do
      outcome =
        ReaderExamples.ask_map()
        |> Reader.Handler.run(%{host: "localhost", port: 8080})
        |> Run.run()

      assert outcome.result == "localhost:8080"
    end

    test "ask with different environment types - atom" do
      outcome =
        ReaderExamples.ask_atom()
        |> Reader.Handler.run(:production)
        |> Run.run()

      assert outcome.result == {:got, :production}
    end

    test "ask with different environment types - string" do
      outcome =
        ReaderExamples.ask_string()
        |> Reader.Handler.run("World")
        |> Run.run()

      assert outcome.result == "Hello, World!"
    end

    test "Reader with State effect" do
      outcome =
        ReaderExamples.reader_with_state()
        |> Reader.Handler.run(3)
        |> State.Handler.run(5)
        |> Run.run()

      assert outcome.result == 15
      assert outcome.outputs[State.Handler] == 15
    end

    test "Reader used in function calls" do
      outcome =
        ReaderExamples.use_config()
        |> Reader.Handler.run(%{debug: true})
        |> Run.run()

      assert outcome.result == {:using, %{debug: true}}
    end

    test "Reader environment is read-only" do
      original_env = %{value: 42}

      outcome =
        ReaderExamples.read_only_env()
        |> Reader.Handler.run(original_env)
        |> Run.run()

      {env1, env2} = outcome.result
      assert env1 == original_env
      assert env2 == original_env
      assert env1 == env2
    end

    test "Reader with complex nested structure" do
      config = %{
        database: %{host: "db.example.com", port: 5432},
        api: %{base_url: "https://api.example.com"}
      }

      outcome =
        ReaderExamples.complex_nested()
        |> Reader.Handler.run(config)
        |> Run.run()

      assert outcome.result == %{
               db: %{host: "db.example.com", port: 5432},
               api: %{base_url: "https://api.example.com"}
             }
    end

    test "Reader propagates through multiple function calls" do
      outcome =
        ReaderExamples.level1()
        |> Reader.Handler.run(:deep_value)
        |> Run.run()

      assert outcome.result == :deep_value
    end
  end

  describe "Reader.Local higher-order operation" do
    test "basic local modification" do
      computation =
        hefty do
          base_config <- Reader.ask()

          result <-
            Reader.local(
              fn config -> %{config | debug: true} end,
              hefty do
                cfg <- Reader.ask()
                return(cfg.debug)
              end
            )

          final_config <- Reader.ask()
          return({base_config.debug, result, final_config.debug})
        end

      outcome =
        computation
        |> Reader.Algebra.run()
        |> Lift.Algebra.run()
        |> Reader.Handler.run(%{debug: false})
        |> Run.run()

      # Base config has debug: false, inside local it's true, after local it's false again
      assert outcome.result == {false, true, false}
    end

    test "nested local scopes" do
      computation =
        hefty do
          result <-
            Reader.local(
              fn config -> %{config | level: 1} end,
              hefty do
                level1 <- Reader.ask()

                result <-
                  Reader.local(
                    fn config -> %{config | level: 2} end,
                    hefty do
                      level2 <- Reader.ask()
                      return(level2.level)
                    end
                  )

                return({level1.level, result})
              end
            )

          base <- Reader.ask()
          return({base.level, result})
        end

      outcome =
        Run.run(
          computation,
          [Reader.Algebra, Lift.Algebra],
          [Reader.Handler],
          %{Reader.Handler => %{level: 0}}
        )

      # Base is 0, first local sees 1, second local sees 2
      assert outcome.result == {0, {1, 2}}
    end

    test "local with state effects" do
      computation =
        hefty do
          # Read multiplier from environment, counter from state
          result <-
            Reader.local(
              fn multiplier -> multiplier * 2 end,
              hefty do
                mult <- Reader.ask()
                counter <- State.get()
                _unit <- State.put(counter * mult)
                new_counter <- State.get()
                return(new_counter)
              end
            )

          # Outside local, state changes persist but environment is restored
          final_mult <- Reader.ask()
          final_counter <- State.get()
          return({result, final_mult, final_counter})
        end

      outcome =
        Run.run(
          computation,
          [Reader.Algebra, Lift.Algebra],
          [Reader.Handler, State.Handler],
          %{Reader.Handler => 3, State.Handler => 5}
        )

      # Inside local: multiplier is 6 (3 * 2), counter becomes 30 (5 * 6)
      # Outside local: multiplier is 3, counter is 30 (state persists)
      assert outcome.result == {30, 3, 30}
      assert outcome.outputs[State.Handler] == 30
    end

    test "multiple local scopes with different modifiers" do
      computation =
        hefty do
          result1 <-
            Reader.local(
              fn n -> n + 10 end,
              hefty do
                val <- Reader.ask()
                return(val)
              end
            )

          result2 <-
            Reader.local(
              fn n -> n * 2 end,
              hefty do
                val <- Reader.ask()
                return(val)
              end
            )

          base <- Reader.ask()
          return({result1, result2, base})
        end

      outcome =
        Run.run(
          computation,
          [Reader.Algebra, Lift.Algebra],
          [Reader.Handler],
          %{Reader.Handler => 5}
        )

      # First local: 5 + 10 = 15
      # Second local: 5 * 2 = 10
      # Base: 5
      assert outcome.result == {15, 10, 5}
    end

    test "local with map environment modifications" do
      computation =
        hefty do
          result <-
            Reader.local(
              fn config -> Map.put(config, :auth, "Bearer token123") end,
              hefty do
                cfg <- Reader.ask()
                return(cfg.auth)
              end
            )

          base_config <- Reader.ask()
          return({result, Map.get(base_config, :auth)})
        end

      outcome =
        Run.run(
          computation,
          [Reader.Algebra, Lift.Algebra],
          [Reader.Handler],
          %{Reader.Handler => %{host: "api.example.com"}}
        )

      # Inside local: auth header is present
      # Outside local: auth header is absent
      assert outcome.result == {"Bearer token123", nil}
    end

    test "local preserves environment outside scope" do
      computation =
        hefty do
          before <- Reader.ask()

          _result <-
            Reader.local(
              fn _config -> %{completely: "different"} end,
              hefty do
                inside <- Reader.ask()
                return(inside)
              end
            )

          after_local <- Reader.ask()
          return({before, after_local})
        end

      original_config = %{original: "config", value: 42}

      outcome =
        Run.run(
          computation,
          [Reader.Algebra, Lift.Algebra],
          [Reader.Handler],
          %{Reader.Handler => original_config}
        )

      # Environment is restored after local scope
      {before, after_local} = outcome.result
      assert before == original_config
      assert after_local == original_config
    end

    test "local with complex nested operations" do
      computation =
        hefty do
          result <-
            Reader.local(
              fn config -> %{config | api_version: "v2"} end,
              hefty do
                # Multiple operations within local scope
                cfg1 <- Reader.ask()
                _unit <- State.put(cfg1.api_version)

                cfg2 <- Reader.ask()
                version <- State.get()

                return({cfg2.api_version, version})
              end
            )

          base_config <- Reader.ask()
          final_state <- State.get()
          return({result, base_config.api_version, final_state})
        end

      outcome =
        Run.run(
          computation,
          [Reader.Algebra, Lift.Algebra],
          [Reader.Handler, State.Handler],
          %{Reader.Handler => %{api_version: "v1"}, State.Handler => "none"}
        )

      # Inside local: api_version is "v2", state becomes "v2"
      # Outside local: api_version is "v1", state is "v2" (persists)
      assert outcome.result == {{"v2", "v2"}, "v1", "v2"}
    end

    test "empty local (identity function)" do
      computation =
        hefty do
          result <-
            Reader.local(
              fn config -> config end,
              hefty do
                cfg <- Reader.ask()
                return(cfg)
              end
            )

          return(result)
        end

      outcome =
        Run.run(
          computation,
          [Reader.Algebra, Lift.Algebra],
          [Reader.Handler],
          %{Reader.Handler => %{value: 123}}
        )

      # Identity function doesn't change environment
      assert outcome.result == %{value: 123}
    end

    test "local with coroutine yield - environment preserved across suspension" do
      alias Freyja.Effects.Coroutine

      computation =
        hefty do
          base_env <- Reader.ask()

          result <-
            Reader.local(
              fn env -> %{env | scope: "local"} end,
              hefty do
                # Read modified env before yield
                env_before <- Reader.ask()
                # Yield and suspend
                resume_value <- Coroutine.yield({:yielded, env_before.scope})
                # Read modified env after resume - should still be "local"
                env_after <- Reader.ask()
                return({env_before.scope, resume_value, env_after.scope})
              end
            )

          # After local scope, environment is restored
          final_env <- Reader.ask()
          return({base_env.scope, result, final_env.scope})
        end

      # Initial run - suspends inside local scope
      outcome =
        Run.run(
          computation,
          [Reader.Algebra, Lift.Algebra],
          [Reader.Handler, Coroutine.Handler],
          %{Reader.Handler => %{scope: "base"}}
        )

      # Should suspend with modified environment visible
      assert {:suspend, {:yielded, "local"}, _continuation} = outcome.result

      # Resume the computation
      outcome2 = Run.resume(outcome, :resumed)

      # After resume, local scope still applies, then restores to base
      # Result structure: {base_scope, {before_scope, resume_value, after_scope}, final_scope}
      assert {:done, {"base", {"local", :resumed, "local"}, "base"}} = outcome2.result
    end
  end
end
