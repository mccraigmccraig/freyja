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
      put(new_value)
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
      runner = Run.with_handlers(r: {Reader.Handler, %{config: "test"}})
      outcome = Run.run(ReaderExamples.simple_ask(), runner)

      assert outcome.result == %{config: "test"}
    end

    test "nested ask calls return same environment" do
      runner = Run.with_handlers(r: {Reader.Handler, :test_env})
      outcome = Run.run(ReaderExamples.nested_ask(), runner)

      assert outcome.result == {:test_env, :test_env}
    end

    test "ask with different environment types - map" do
      runner = Run.with_handlers(r: {Reader.Handler, %{host: "localhost", port: 8080}})
      outcome = Run.run(ReaderExamples.ask_map(), runner)

      assert outcome.result == "localhost:8080"
    end

    test "ask with different environment types - atom" do
      runner = Run.with_handlers(r: {Reader.Handler, :production})
      outcome = Run.run(ReaderExamples.ask_atom(), runner)

      assert outcome.result == {:got, :production}
    end

    test "ask with different environment types - string" do
      runner = Run.with_handlers(r: {Reader.Handler, "World"})
      outcome = Run.run(ReaderExamples.ask_string(), runner)

      assert outcome.result == "Hello, World!"
    end

    test "Reader with State effect" do
      runner =
        Run.with_handlers(
          r: {Reader.Handler, 3},
          s: {State.Handler, 5}
        )

      outcome = Run.run(ReaderExamples.reader_with_state(), runner)

      assert outcome.result == 15
      assert outcome.outputs.s == 15
    end

    test "Reader used in function calls" do
      runner = Run.with_handlers(r: {Reader.Handler, %{debug: true}})
      outcome = Run.run(ReaderExamples.use_config(), runner)

      assert outcome.result == {:using, %{debug: true}}
    end

    test "Reader environment is read-only" do
      original_env = %{value: 42}
      runner = Run.with_handlers(r: {Reader.Handler, original_env})
      outcome = Run.run(ReaderExamples.read_only_env(), runner)

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

      runner = Run.with_handlers(r: {Reader.Handler, config})
      outcome = Run.run(ReaderExamples.complex_nested(), runner)

      assert outcome.result == %{
               db: %{host: "db.example.com", port: 5432},
               api: %{base_url: "https://api.example.com"}
             }
    end

    test "Reader propagates through multiple function calls" do
      runner = Run.with_handlers(r: {Reader.Handler, :deep_value})
      outcome = Run.run(ReaderExamples.level1(), runner)

      assert outcome.result == :deep_value
    end
  end
end
