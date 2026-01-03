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
        |> State.with_handler(10)

      assert Comp.run!(computation, Env.new()) == 11
    end

    test "multiple effect bindings" do
      computation =
        comp do
          x <- State.get()
          _ <- State.put(x + 1)
          y <- State.get()
          return({x, y})
        end
        |> State.with_handler(5)

      assert Comp.run!(computation, Env.new()) == {5, 6}
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
        |> State.with_handler(3)

      assert Comp.run!(computation, Env.new()) == {3, 6, 6}
    end

    test "ignoring result with _" do
      computation =
        comp do
          _ <- State.put(100)
          x <- State.get()
          return(x)
        end
        |> State.with_handler(0)

      assert Comp.run!(computation, Env.new()) == 100
    end

    test "with Reader effect" do
      computation =
        comp do
          ctx <- Reader.ask()
          return(ctx.value * 2)
        end
        |> Reader.with_handler(%{value: 21})

      assert Comp.run!(computation, Env.new()) == 42
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
        |> Reader.with_handler(%{increment: 10})
        |> State.with_handler(5)

      assert Comp.run!(computation, Env.new()) == {5, 15}
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
        |> State.with_handler(0)

      assert Comp.run!(outer, Env.new()) == 21
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
      assert Comp.run!(simple_get() |> State.with_handler(42), Env.new()) == 42
    end

    test "defcomp with effects" do
      assert Comp.run!(increment_and_get() |> State.with_handler(10), Env.new()) == {10, 11}
    end

    test "defcomp with single arg" do
      assert Comp.run!(with_arg(3) |> State.with_handler(5), Env.new()) == 15
    end

    test "defcomp with multiple args" do
      assert Comp.run!(with_multiple_args(5, 3) |> State.with_handler(10), Env.new()) == 18
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
      assert Comp.run!(uses_private() |> State.with_handler(21), Env.new()) == 42
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
      computation = UseSyntaxExample.get_doubled() |> State.with_handler(10)
      assert Comp.run!(computation, Env.new()) == 20
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
        |> Throw.with_handler()

      assert Comp.run!(computation, Env.new()) == :caught
    end

    test "passes through normal completion" do
      computation =
        comp do
          return(42)
        catch
          _ -> return(:caught)
        end
        |> Throw.with_handler()

      assert Comp.run!(computation, Env.new()) == 42
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
        |> Throw.with_handler()

      assert Comp.run!(computation, Env.new()) == :not_found_handled
    end

    test "unhandled error is re-thrown" do
      computation =
        comp do
          _ <- Throw.throw(:unhandled)
          return(:never_reached)
        catch
          :specific_error -> return(:handled)
        end
        |> Throw.with_handler()

      {result, _env} = Comp.run(computation, Env.new())
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
        |> Throw.with_handler()

      assert Comp.run!(computation, Env.new()) == {:caught, :any_error}
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
        |> State.with_handler(0)
        |> Throw.with_handler()

      assert Comp.run!(computation, Env.new()) == {:recovered, 100}
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
        |> Reader.with_handler(%{default: :fallback})
        |> Throw.with_handler()

      assert Comp.run!(computation, Env.new()) == {:recovered, :fallback}
    end

    test "catch handler returning {:ok, value} is not incorrectly unwrapped" do
      computation =
        comp do
          _ <- Throw.throw(:error)
          return(:never_reached)
        catch
          :error -> return({:ok, :recovered})
        end
        |> Throw.with_handler()

      assert Comp.run!(computation, Env.new()) == {:ok, :recovered}
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
        |> Throw.with_handler()

      assert Comp.run!(outer, Env.new()) == {:outer_got, :inner_caught}
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
        |> Throw.with_handler()

      assert Comp.run!(outer, Env.new()) == :outer_caught_inner_error
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
      assert Comp.run!(safe_divide(10, 0) |> Throw.with_handler(), Env.new()) == :infinity
    end

    test "defcomp with catch passes through success" do
      assert Comp.run!(safe_divide(10, 2) |> Throw.with_handler(), Env.new()) == 5
    end

    test "defcomp with catch and args" do
      computation = fetch_with_default(:missing, :default_value) |> Throw.with_handler()
      assert Comp.run!(computation, Env.new()) == :default_value
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
      assert Comp.run!(uses_private_risky() |> Throw.with_handler(), Env.new()) ==
               {:got, :privately_handled}
    end
  end

  describe "else clause" do
    test "handles pattern match failure in <-" do
      computation =
        comp do
          {:ok, x} <- Comp.pure({:error, :not_found})
          return(x)
        else
          {:error, reason} -> return({:failed, reason})
        end
        |> Throw.with_handler()

      assert Comp.run!(computation, Env.new()) == {:failed, :not_found}
    end

    test "passes through successful match" do
      computation =
        comp do
          {:ok, x} <- Comp.pure({:ok, 42})
          return(x)
        else
          {:error, _} -> return(:failed)
        end
        |> Throw.with_handler()

      assert Comp.run!(computation, Env.new()) == 42
    end

    test "handles multiple patterns in else" do
      computation =
        comp do
          {:ok, x} <- Comp.pure({:error, :specific})
          return(x)
        else
          {:error, :specific} -> return(:specific_handled)
          {:error, _} -> return(:generic_error)
          other -> return({:unexpected, other})
        end
        |> Throw.with_handler()

      assert Comp.run!(computation, Env.new()) == :specific_handled
    end

    test "unhandled match failure propagates as MatchFailed" do
      computation =
        comp do
          {:ok, x} <- Comp.pure({:error, :unhandled})
          return(x)
        else
          {:error, :specific} -> return(:handled)
        end
        |> Throw.with_handler()

      {result, _} = Comp.run(computation, Env.new())
      assert %Comp.Throw{error: %Comp.MatchFailed{value: {:error, :unhandled}}} = result
    end

    test "else with catch-all handles any mismatch" do
      computation =
        comp do
          {:ok, x} <- Comp.pure(:something_else)
          return(x)
        else
          other -> return({:caught, other})
        end
        |> Throw.with_handler()

      assert Comp.run!(computation, Env.new()) == {:caught, :something_else}
    end

    test "simple patterns don't trigger else" do
      # Simple variable patterns always match, so else is never called
      computation =
        comp do
          x <- Comp.pure(42)
          return(x * 2)
        else
          _ -> return(:should_not_reach)
        end
        |> Throw.with_handler()

      assert Comp.run!(computation, Env.new()) == 84
    end

    test "handles pattern match failure in = binding" do
      computation =
        comp do
          x <- Comp.pure(10)
          {:ok, y} = {:error, :oops}
          return(x + y)
        else
          {:error, reason} -> return({:assignment_failed, reason})
        end
        |> Throw.with_handler()

      assert Comp.run!(computation, Env.new()) == {:assignment_failed, :oops}
    end

    test "else handler can use effects" do
      computation =
        comp do
          {:ok, x} <- Comp.pure({:error, :failed})
          return(x)
        else
          {:error, _} ->
            s <- State.get()
            return({:recovered_with_state, s})
        end
        |> State.with_handler(100)
        |> Throw.with_handler()

      assert Comp.run!(computation, Env.new()) == {:recovered_with_state, 100}
    end

    test "multiple <- bindings with else" do
      computation =
        comp do
          {:ok, a} <- Comp.pure({:ok, 1})
          {:ok, b} <- Comp.pure({:ok, 2})
          {:ok, c} <- Comp.pure({:error, :third_failed})
          return(a + b + c)
        else
          {:error, reason} -> return({:failed_at, reason})
        end
        |> Throw.with_handler()

      assert Comp.run!(computation, Env.new()) == {:failed_at, :third_failed}
    end
  end

  describe "else with catch" do
    test "else inside catch - throws from else are caught" do
      computation =
        comp do
          {:ok, x} <- Comp.pure({:error, :match_fail})
          return(x)
        else
          {:error, :match_fail} ->
            _ <- Throw.throw(:else_threw)
            return(:never)
        catch
          :else_threw -> return(:catch_got_else_throw)
        end
        |> Throw.with_handler()

      assert Comp.run!(computation, Env.new()) == :catch_got_else_throw
    end

    test "else inside catch - throws from body pass through else to catch" do
      computation =
        comp do
          _ <- Throw.throw(:body_threw)
          {:ok, x} <- Comp.pure({:ok, 42})
          return(x)
        else
          {:error, _} -> return(:else_handled)
        catch
          :body_threw -> return(:catch_got_body_throw)
        end
        |> Throw.with_handler()

      assert Comp.run!(computation, Env.new()) == :catch_got_body_throw
    end

    test "else handles match failure, catch handles throw" do
      computation =
        comp do
          {:ok, x} <- Comp.pure({:error, :no_match})
          return(x)
        else
          {:error, :no_match} -> return(:else_handled_match)
        catch
          :some_error -> return(:catch_handled_throw)
        end
        |> Throw.with_handler()

      assert Comp.run!(computation, Env.new()) == :else_handled_match
    end

    test "ordering validation - else must come before catch" do
      # This should raise a CompileError at compile time
      # We can't easily test compile errors, but we document the behavior
      assert_raise CompileError, ~r/else.*must come before.*catch/, fn ->
        Code.compile_string("""
        import Skuld.Comp.CompBlock
        comp do
          return(:ok)
        catch
          _ -> return(:caught)
        else
          _ -> return(:else)
        end
        """)
      end
    end
  end

  describe "defcomp with else" do
    defcomp safe_unwrap(result) do
      {:ok, value} <- Comp.pure(result)
      return(value)
    else
      {:error, reason} -> return({:failed, reason})
      other -> return({:unexpected, other})
    end

    test "defcomp with else handles match failure" do
      assert Comp.run!(safe_unwrap({:ok, 42}) |> Throw.with_handler(), Env.new()) == 42

      assert Comp.run!(safe_unwrap({:error, :oops}) |> Throw.with_handler(), Env.new()) ==
               {:failed, :oops}

      assert Comp.run!(safe_unwrap(:weird) |> Throw.with_handler(), Env.new()) ==
               {:unexpected, :weird}
    end
  end

  describe "defcomp with else and catch" do
    defcomp complex_handler(input) do
      {:ok, x} <- Comp.pure(input)
      _ <- if x < 0, do: Throw.throw(:negative), else: Comp.pure(:ok)
      return(x * 2)
    else
      {:error, reason} -> return({:match_failed, reason})
    catch
      :negative -> return(:was_negative)
    end

    test "defcomp with else and catch - match failure" do
      assert Comp.run!(complex_handler({:error, :bad}) |> Throw.with_handler(), Env.new()) ==
               {:match_failed, :bad}
    end

    test "defcomp with else and catch - throw" do
      assert Comp.run!(complex_handler({:ok, -5}) |> Throw.with_handler(), Env.new()) ==
               :was_negative
    end

    test "defcomp with else and catch - success" do
      assert Comp.run!(complex_handler({:ok, 10}) |> Throw.with_handler(), Env.new()) == 20
    end
  end
end
