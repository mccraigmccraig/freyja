defmodule Skuld.Comp.CompBlockTest do
  use ExUnit.Case, async: true

  import Skuld.Comp.CompBlock

  alias Skuld.Comp
  alias Skuld.Effects.State
  alias Skuld.Effects.Reader
  alias Skuld.Effects.Throw
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

  describe "catch clause" do
    test "catches thrown error" do
      computation =
        comp do
          _ <- Throw.throw(:my_error)
          return(:never_reached)
        catch
          :my_error -> return(:caught)
        end

      env = Env.new() |> Throw.handler()
      assert Comp.run!(computation, env) == :caught
    end

    test "passes through normal completion" do
      computation =
        comp do
          return(42)
        catch
          _ -> return(:caught)
        end

      env = Env.new() |> Throw.handler()
      assert Comp.run!(computation, env) == 42
    end

    test "pattern matches on error value" do
      computation =
        comp do
          _ <- Throw.throw({:error, :not_found})
          return(:never_reached)
        catch
          {:error, :not_found} -> return(:not_found_handled)
          {:error, reason} -> return({:other_error, reason})
        end

      env = Env.new() |> Throw.handler()
      assert Comp.run!(computation, env) == :not_found_handled
    end

    test "unhandled error is re-thrown" do
      computation =
        comp do
          _ <- Throw.throw(:unhandled)
          return(:never_reached)
        catch
          :specific_error -> return(:handled)
        end

      env = Env.new() |> Throw.handler()
      {result, _env} = Comp.run(computation, env)
      assert %Comp.Throw{error: :unhandled} = result
    end

    test "catch-all clause handles any error" do
      computation =
        comp do
          _ <- Throw.throw(:any_error)
          return(:never_reached)
        catch
          err -> return({:caught, err})
        end

      env = Env.new() |> Throw.handler()
      assert Comp.run!(computation, env) == {:caught, :any_error}
    end

    test "catch with state effects preserves state changes before throw" do
      computation =
        comp do
          _ <- State.put(100)
          _ <- Throw.throw(:error)
          return(:never_reached)
        catch
          :error ->
            x <- State.get()
            return({:recovered, x})
        end

      env =
        Env.new()
        |> Throw.handler()
        |> State.handler(0)

      assert Comp.run!(computation, env) == {:recovered, 100}
    end

    test "catch handler can use effects" do
      computation =
        comp do
          _ <- Throw.throw(:error)
          return(:never_reached)
        catch
          :error ->
            ctx <- Reader.ask()
            return({:recovered, ctx.default})
        end

      env =
        Env.new()
        |> Throw.handler()
        |> Reader.handler(%{default: :fallback})

      assert Comp.run!(computation, env) == {:recovered, :fallback}
    end

    test "catch handler returning {:ok, value} is not incorrectly unwrapped" do
      computation =
        comp do
          _ <- Throw.throw(:error)
          return(:never_reached)
        catch
          :error -> return({:ok, :recovered})
        end

      env = Env.new() |> Throw.handler()
      assert Comp.run!(computation, env) == {:ok, :recovered}
    end

    test "nested catch - inner catches first" do
      inner =
        comp do
          _ <- Throw.throw(:inner_error)
          return(:never)
        catch
          :inner_error -> return(:inner_caught)
        end

      outer =
        comp do
          result <- inner
          return({:outer_got, result})
        catch
          _ -> return(:outer_caught)
        end

      env = Env.new() |> Throw.handler()
      assert Comp.run!(outer, env) == {:outer_got, :inner_caught}
    end

    test "outer catch handles errors from inner when not caught" do
      inner =
        comp do
          _ <- Throw.throw(:uncaught_inner)
          return(:never)
        catch
          :different_error -> return(:inner_caught)
        end

      outer =
        comp do
          result <- inner
          return({:outer_got, result})
        catch
          :uncaught_inner -> return(:outer_caught_inner_error)
        end

      env = Env.new() |> Throw.handler()
      assert Comp.run!(outer, env) == :outer_caught_inner_error
    end
  end

  describe "defcomp with catch" do
    defcomp safe_divide(a, b) do
      _ <- if b == 0, do: Throw.throw(:divide_by_zero), else: Comp.pure(:ok)
      return(div(a, b))
    catch
      :divide_by_zero -> return(:infinity)
    end

    defcomp fetch_with_default(key, default) do
      _ <- Throw.throw({:not_found, key})
      return(:never)
    catch
      {:not_found, _} -> return(default)
    end

    test "defcomp with catch handles error" do
      env = Env.new() |> Throw.handler()
      assert Comp.run!(safe_divide(10, 0), env) == :infinity
    end

    test "defcomp with catch passes through success" do
      env = Env.new() |> Throw.handler()
      assert Comp.run!(safe_divide(10, 2), env) == 5
    end

    test "defcomp with catch and args" do
      env = Env.new() |> Throw.handler()
      assert Comp.run!(fetch_with_default(:missing, :default_value), env) == :default_value
    end
  end

  describe "defcompp with catch" do
    defcompp private_risky do
      _ <- Throw.throw(:private_error)
      return(:never)
    catch
      :private_error -> return(:privately_handled)
    end

    defcomp uses_private_risky do
      result <- private_risky()
      return({:got, result})
    end

    test "defcompp with catch works" do
      env = Env.new() |> Throw.handler()
      assert Comp.run!(uses_private_risky(), env) == {:got, :privately_handled}
    end
  end
end
