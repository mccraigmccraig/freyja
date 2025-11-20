defmodule Freyja.Effects.ReaderTest do
  use ExUnit.Case

  alias Freyja.Effects.Reader
  alias Freyja.Effects.State
  alias Freyja.Run

  defmodule ReaderExamples do
    import Freyja.Con

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
      outcome = Run.run(ReaderExamples.simple_ask(), [Reader.Handler], %{Reader.Handler => %{config: "test"}})

      assert outcome.result == %{config: "test"}
    end

    test "nested ask calls return same environment" do
      outcome = Run.run(ReaderExamples.nested_ask(), [Reader.Handler], %{Reader.Handler => :test_env})

      assert outcome.result == {:test_env, :test_env}
    end

    test "ask with different environment types - map" do
      outcome = Run.run(ReaderExamples.ask_map(), [Reader.Handler], %{Reader.Handler => %{host: "localhost", port: 8080}})

      assert outcome.result == "localhost:8080"
    end

    test "ask with different environment types - atom" do
      outcome = Run.run(ReaderExamples.ask_atom(), [Reader.Handler], %{Reader.Handler => :production})

      assert outcome.result == {:got, :production}
    end

    test "ask with different environment types - string" do
      outcome = Run.run(ReaderExamples.ask_string(), [Reader.Handler], %{Reader.Handler => "World"})

      assert outcome.result == "Hello, World!"
    end

    test "Reader with State effect" do
      outcome = Run.run(ReaderExamples.reader_with_state(), [Reader.Handler, State.Handler], %{Reader.Handler => 3, State.Handler => 5})

      assert outcome.result == 15
      assert outcome.outputs[State.Handler] == 15
    end

    test "Reader used in function calls" do
      outcome = Run.run(ReaderExamples.use_config(), [Reader.Handler], %{Reader.Handler => %{debug: true}})

      assert outcome.result == {:using, %{debug: true}}
    end

    test "Reader environment is read-only" do
      original_env = %{value: 42}
      outcome = Run.run(ReaderExamples.read_only_env(), [Reader.Handler], %{Reader.Handler => original_env})

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

      outcome = Run.run(ReaderExamples.complex_nested(), [Reader.Handler], %{Reader.Handler => config})

      assert outcome.result == %{
               db: %{host: "db.example.com", port: 5432},
               api: %{base_url: "https://api.example.com"}
             }
    end

    test "Reader propagates through multiple function calls" do
      outcome = Run.run(ReaderExamples.level1(), [Reader.Handler], %{Reader.Handler => :deep_value})

      assert outcome.result == :deep_value
    end
  end
end
