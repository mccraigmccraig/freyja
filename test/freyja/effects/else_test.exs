defmodule Freyja.Effects.ElseTest do
  use ExUnit.Case, async: true

  alias Freyja.Effects.{Else, Lift, Throw, Catch}
  alias Freyja.Effects.State
  alias Freyja.Run

  describe "basic else functionality" do
    test "else handles pattern match failure in <- binding" do
      use Freyja.Syntax

      # Function that returns {:error, reason} instead of {:ok, value}
      get_value = fn -> Freyja.Hefty.pure({:error, :not_found}) end

      comp =
        hefty do
          {:ok, a} = x <- get_value.()
          # check assignments in matches work!
          _ = assert x == {:ok, {:error, :not_found}}
          return(a)
        else
          {:error, reason} -> return({:handled, reason})
        end

      result =
        comp
        |> Else.Algebra.run()
        |> Lift.Algebra.run()
        |> Throw.Handler.run()
        |> Run.run()

      assert result.result == {:ok, {:handled, :not_found}}
    end

    test "else is not triggered when pattern matches" do
      use Freyja.Syntax

      get_value = fn -> Freyja.Hefty.pure({:ok, 42}) end

      comp =
        hefty do
          {:ok, a} <- get_value.()
          return(a)
        else
          {:error, reason} -> return({:handled, reason})
        end

      result =
        comp
        |> Else.Algebra.run()
        |> Lift.Algebra.run()
        |> Throw.Handler.run()
        |> Run.run()

      assert result.result == {:ok, 42}
    end

    test "simple variable patterns don't trigger else" do
      use Freyja.Syntax

      get_value = fn -> Freyja.Hefty.pure({:error, :not_found}) end

      comp =
        hefty do
          # Simple variable pattern - always matches
          x <- get_value.()
          return(x)
        else
          _ -> return(:should_not_happen)
        end

      result =
        comp
        |> Else.Algebra.run()
        |> Lift.Algebra.run()
        |> Throw.Handler.run()
        |> Run.run()

      # The value passes through because `x` always matches
      assert result.result == {:ok, {:error, :not_found}}
    end
  end

  describe "multiple else clauses" do
    test "matches first matching else clause" do
      use Freyja.Syntax

      get_value = fn val -> Freyja.Hefty.pure(val) end

      make_comp = fn val ->
        hefty do
          {:ok, a} <- get_value.(val)
          return(a)
        else
          {:error, :not_found} -> return(:not_found_handled)
          {:error, :timeout} -> return(:timeout_handled)
          {:error, other} -> return({:other_error, other})
        end
      end

      # Test :not_found
      result1 =
        make_comp.({:error, :not_found})
        |> Else.Algebra.run()
        |> Lift.Algebra.run()
        |> Throw.Handler.run()
        |> Run.run()

      assert result1.result == {:ok, :not_found_handled}

      # Test :timeout
      result2 =
        make_comp.({:error, :timeout})
        |> Else.Algebra.run()
        |> Lift.Algebra.run()
        |> Throw.Handler.run()
        |> Run.run()

      assert result2.result == {:ok, :timeout_handled}

      # Test other error
      result3 =
        make_comp.({:error, :something_else})
        |> Else.Algebra.run()
        |> Lift.Algebra.run()
        |> Throw.Handler.run()
        |> Run.run()

      assert result3.result == {:ok, {:other_error, :something_else}}
    end
  end

  describe "else with = bindings" do
    test "else handles pattern match failure in = binding" do
      use Freyja.Syntax

      comp =
        hefty do
          {:ok, a} = {:error, :oops}
          return(a)
        else
          {:error, reason} -> return({:handled, reason})
        end

      result =
        comp
        |> Else.Algebra.run()
        |> Lift.Algebra.run()
        |> Throw.Handler.run()
        |> Run.run()

      assert result.result == {:ok, {:handled, :oops}}
    end
  end

  describe "else with complex patterns" do
    test "tuple patterns" do
      use Freyja.Syntax

      get_value = fn -> Freyja.Hefty.pure({:error, :reason}) end

      comp =
        hefty do
          {:ok, a, b} <- get_value.()
          return({a, b})
        else
          {:error, reason} -> return({:failed, reason})
        end

      result =
        comp
        |> Else.Algebra.run()
        |> Lift.Algebra.run()
        |> Throw.Handler.run()
        |> Run.run()

      assert result.result == {:ok, {:failed, :reason}}
    end

    test "list patterns" do
      use Freyja.Syntax

      get_value = fn -> Freyja.Hefty.pure([]) end

      comp =
        hefty do
          [h | _t] <- get_value.()
          return(h)
        else
          [] -> return(:empty_list)
        end

      result =
        comp
        |> Else.Algebra.run()
        |> Lift.Algebra.run()
        |> Throw.Handler.run()
        |> Run.run()

      assert result.result == {:ok, :empty_list}
    end

    test "map patterns" do
      use Freyja.Syntax

      get_value = fn -> Freyja.Hefty.pure(%{other: :value}) end

      comp =
        hefty do
          %{key: value} <- get_value.()
          return(value)
        else
          %{other: v} -> return({:other, v})
        end

      result =
        comp
        |> Else.Algebra.run()
        |> Lift.Algebra.run()
        |> Throw.Handler.run()
        |> Run.run()

      assert result.result == {:ok, {:other, :value}}
    end

    test "literal patterns" do
      use Freyja.Syntax

      get_value = fn -> Freyja.Hefty.pure(:not_ok) end

      comp =
        hefty do
          :ok <- get_value.()
          return(:success)
        else
          :not_ok -> return(:failed)
        end

      result =
        comp
        |> Else.Algebra.run()
        |> Lift.Algebra.run()
        |> Throw.Handler.run()
        |> Run.run()

      assert result.result == {:ok, :failed}
    end
  end

  describe "unhandled pattern in else" do
    test "unhandled value converts to throw" do
      use Freyja.Syntax

      get_value = fn -> Freyja.Hefty.pure(:unexpected) end

      comp =
        hefty do
          {:ok, a} <- get_value.()
          return(a)
        else
          {:error, _} ->
            return(:error_handled)
            # :unexpected is not handled, should become throw
        end

      result =
        comp
        |> Else.Algebra.run()
        |> Lift.Algebra.run()
        |> Throw.Handler.run()
        |> Run.run()

      assert result.result == {:error, {:bind_match_failed, :unexpected}}
    end
  end

  describe "nested else blocks" do
    test "inner else handles its own failures" do
      use Freyja.Syntax

      outer_value = fn -> Freyja.Hefty.pure({:ok, 1}) end
      inner_value = fn -> Freyja.Hefty.pure({:error, :inner_fail}) end

      comp =
        hefty do
          {:ok, a} <- outer_value.()

          b <-
            hefty do
              {:ok, x} <- inner_value.()
              return(x)
            else
              {:error, reason} -> return({:inner_handled, reason})
            end

          return({a, b})
        else
          {:error, _} -> return(:outer_handled)
        end

      result =
        comp
        |> Else.Algebra.run()
        |> Lift.Algebra.run()
        |> Throw.Handler.run()
        |> Run.run()

      # Inner else handles the inner failure
      assert result.result == {:ok, {1, {:inner_handled, :inner_fail}}}
    end

    test "outer else doesn't see inner failures" do
      use Freyja.Syntax

      outer_value = fn -> Freyja.Hefty.pure({:error, :outer_fail}) end

      comp =
        hefty do
          {:ok, a} <- outer_value.()

          b <-
            hefty do
              {:ok, x} <- Freyja.Hefty.pure({:ok, 42})
              return(x)
            else
              {:error, _} -> return(:inner_handled)
            end

          return({a, b})
        else
          {:error, reason} -> return({:outer_handled, reason})
        end

      result =
        comp
        |> Else.Algebra.run()
        |> Lift.Algebra.run()
        |> Throw.Handler.run()
        |> Run.run()

      # Outer else handles the outer failure
      assert result.result == {:ok, {:outer_handled, :outer_fail}}
    end
  end

  describe "combined else and catch" do
    test "else handles match failures, catch handles throws" do
      use Freyja.Syntax

      get_value = fn -> Freyja.Hefty.pure({:error, :match_fail}) end

      comp =
        hefty do
          {:ok, a} <- get_value.()
          return(a)
        else
          {:error, reason} -> return({:match_handled, reason})
        catch
          thrown -> return({:caught, thrown})
        end

      result =
        comp
        |> Else.Algebra.run()
        |> Catch.Algebra.run()
        |> Lift.Algebra.run()
        |> Throw.Handler.run()
        |> Run.run()

      assert result.result == {:ok, {:match_handled, :match_fail}}
    end

    test "catch handles throws from main computation" do
      use Freyja.Syntax

      comp =
        hefty do
          _ <- Lift.lift(Throw.throw_error(:thrown_error))
          return(:unreachable)
        else
          _ -> return(:match_handled)
        catch
          thrown -> return({:caught, thrown})
        end

      result =
        comp
        |> Else.Algebra.run()
        |> Catch.Algebra.run()
        |> Lift.Algebra.run()
        |> Throw.Handler.run()
        |> Run.run()

      assert result.result == {:ok, {:caught, :thrown_error}}
    end

    test "catch handles throws from else handler" do
      use Freyja.Syntax

      get_value = fn -> Freyja.Hefty.pure({:error, :fail}) end

      comp =
        hefty do
          {:ok, a} <- get_value.()
          return(a)
        else
          {:error, _} ->
            # Else handler throws
            _ <- Lift.lift(Throw.throw_error(:else_threw))
            return(:unreachable)
        catch
          thrown -> return({:caught_from_else, thrown})
        end

      result =
        comp
        |> Else.Algebra.run()
        |> Catch.Algebra.run()
        |> Lift.Algebra.run()
        |> Throw.Handler.run()
        |> Run.run()

      # Catch (outer) catches the throw from else handler
      assert result.result == {:ok, {:caught_from_else, :else_threw}}
    end
  end

  describe "else handler can perform effects" do
    test "else handler can use state effects" do
      use Freyja.Syntax

      get_value = fn -> Freyja.Hefty.pure({:error, :fail}) end

      comp =
        hefty do
          {:ok, a} <- get_value.()
          return(a)
        else
          {:error, reason} ->
            _ <- State.put(reason)
            return(:handled)
        end

      result =
        comp
        |> Else.Algebra.run()
        |> Lift.Algebra.run()
        |> Throw.Handler.run()
        |> State.Handler.run(:initial)
        |> Run.run()

      assert result.result == {:ok, :handled}
      assert result.outputs[State.Handler] == :fail
    end
  end

  describe "compile error for wrong clause ordering" do
    test "catch before else raises CompileError" do
      assert_raise CompileError, ~r/else.*must come before.*catch/, fn ->
        Code.compile_string("""
        defmodule TestWrongOrder do
          use Freyja.Syntax

          def test do
            hefty do
              x <- Freyja.Hefty.pure(1)
              return(x)
            catch
              _ -> return(:caught)
            else
              _ -> return(:else)
            end
          end
        end
        """)
      end
    end
  end

  describe "multiple bindings with else" do
    test "else triggers on first failing pattern" do
      use Freyja.Syntax

      comp =
        hefty do
          {:ok, a} <- Freyja.Hefty.pure({:ok, 1})
          {:ok, b} <- Freyja.Hefty.pure({:error, :second_fail})
          {:ok, c} <- Freyja.Hefty.pure({:ok, 3})
          return({a, b, c})
        else
          {:error, reason} -> return({:failed_at, reason})
        end

      result =
        comp
        |> Else.Algebra.run()
        |> Lift.Algebra.run()
        |> Throw.Handler.run()
        |> Run.run()

      assert result.result == {:ok, {:failed_at, :second_fail}}
    end
  end
end
