defmodule Skuld.Comp.CompBlockTest do
  use ExUnit.Case, async: true

  import Skuld.Comp.CompBlock

  alias Skuld.Comp
  alias Skuld.Effects.State
  alias Skuld.Effects.Reader
  alias Skuld.Env

  describe "comp macro" do
    test "single return" do
      computation =
        comp do
          return(42)
        end

      env = Env.new()
      assert Comp.run!(computation, env) == 42
    end

    test "pure binding with =" do
      computation =
        comp do
          x = 10
          y = x + 5
          return(y)
        end

      env = Env.new()
      assert Comp.run!(computation, env) == 15
    end

    test "effect binding with <-" do
      computation =
        comp do
          x <- State.get()
          return(x + 1)
        end

      env =
        Env.new()
        |> State.handler(10)

      assert Comp.run!(computation, env) == 11
    end

    test "multiple effect bindings" do
      computation =
        comp do
          x <- State.get()
          _ <- State.put(x + 1)
          y <- State.get()
          return({x, y})
        end

      env =
        Env.new()
        |> State.handler(5)

      assert Comp.run!(computation, env) == {5, 6}
    end

    test "mixed pure and effect bindings" do
      computation =
        comp do
          x <- State.get()
          y = x * 2
          _ <- State.put(y)
          z <- State.get()
          return({x, y, z})
        end

      env =
        Env.new()
        |> State.handler(3)

      assert Comp.run!(computation, env) == {3, 6, 6}
    end

    test "ignoring result with _" do
      computation =
        comp do
          _ <- State.put(100)
          x <- State.get()
          return(x)
        end

      env =
        Env.new()
        |> State.handler(0)

      assert Comp.run!(computation, env) == 100
    end

    test "with Reader effect" do
      computation =
        comp do
          ctx <- Reader.ask()
          return(ctx.value * 2)
        end

      env =
        Env.new()
        |> Reader.handler(%{value: 21})

      assert Comp.run!(computation, env) == 42
    end

    test "combining multiple effects" do
      computation =
        comp do
          ctx <- Reader.ask()
          x <- State.get()
          _ <- State.put(x + ctx.increment)
          y <- State.get()
          return({x, y})
        end

      env =
        Env.new()
        |> Reader.handler(%{increment: 10})
        |> State.handler(5)

      assert Comp.run!(computation, env) == {5, 15}
    end

    test "nested computations" do
      inner =
        comp do
          x <- State.get()
          return(x * 2)
        end

      outer =
        comp do
          _ <- State.put(10)
          result <- inner
          return(result + 1)
        end

      env =
        Env.new()
        |> State.handler(0)

      assert Comp.run!(outer, env) == 21
    end

    test "pattern matching in binding" do
      computation =
        comp do
          {a, b} <- Comp.pure({1, 2})
          return(a + b)
        end

      env = Env.new()
      assert Comp.run!(computation, env) == 3
    end
  end

  describe "defcomp macro" do
    defcomp simple_get do
      x <- State.get()
      return(x)
    end

    defcomp increment_and_get do
      x <- State.get()
      _ <- State.put(x + 1)
      y <- State.get()
      return({x, y})
    end

    defcomp with_arg(multiplier) do
      x <- State.get()
      return(x * multiplier)
    end

    defcomp with_multiple_args(a, b) do
      x <- State.get()
      return(x + a + b)
    end

    test "defcomp with no args" do
      env =
        Env.new()
        |> State.handler(42)

      assert Comp.run!(simple_get(), env) == 42
    end

    test "defcomp with effects" do
      env =
        Env.new()
        |> State.handler(10)

      assert Comp.run!(increment_and_get(), env) == {10, 11}
    end

    test "defcomp with single arg" do
      env =
        Env.new()
        |> State.handler(5)

      assert Comp.run!(with_arg(3), env) == 15
    end

    test "defcomp with multiple args" do
      env =
        Env.new()
        |> State.handler(10)

      assert Comp.run!(with_multiple_args(5, 3), env) == 18
    end
  end

  describe "defcompp macro" do
    # We can't directly test private functions, but we can test them indirectly

    defcompp private_double do
      x <- State.get()
      return(x * 2)
    end

    defcomp uses_private do
      x <- private_double()
      _ <- State.put(x)
      return(x)
    end

    test "defcompp defines private function usable internally" do
      env =
        Env.new()
        |> State.handler(21)

      assert Comp.run!(uses_private(), env) == 42
    end
  end

  describe "use Skuld.Syntax" do
    defmodule UseSyntaxExample do
      use Skuld.Syntax

      alias Skuld.Effects.State

      defcomp get_doubled do
        x <- State.get()
        return(x * 2)
      end
    end

    test "use Skuld.Syntax imports macros" do
      env =
        Env.new()
        |> State.handler(10)

      assert Comp.run!(UseSyntaxExample.get_doubled(), env) == 20
    end
  end

  describe "edge cases" do
    test "empty block with just return" do
      computation =
        comp do
          return(:ok)
        end

      assert Comp.run!(computation, Env.new()) == :ok
    end

    test "computation as last expression without return" do
      computation =
        comp do
          x <- Comp.pure(10)
          Comp.pure(x + 1)
        end

      assert Comp.run!(computation, Env.new()) == 11
    end

    test "complex pattern in binding" do
      computation =
        comp do
          %{a: a, b: b} <- Comp.pure(%{a: 1, b: 2, c: 3})
          return(a + b)
        end

      assert Comp.run!(computation, Env.new()) == 3
    end
  end
end
