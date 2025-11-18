defmodule Freyja.HeftyMacroTest do
  use ExUnit.Case, async: true

  import Freyja.HeftyMacro

  alias Freyja.Hefty
  alias Freyja.Hefty.Run, as: HeftyRun
  alias Freyja.Hefty.Effects.Lift
  alias Freyja.Effects.Catch
  alias Freyja.Hefty.Effects.HeftyError
  alias Freyja.Hefty.Effects.HeftyError.Handler, as: HeftyErrorHandler
  alias Freyja.Effects.State
  alias Freyja.OkResult

  # Test struct that doesn't implement IHeftySendable
  defmodule CustomStruct do
    defstruct [:value]
  end

  describe "hefty macro" do
    test "simple pure value" do
      result =
        hefty do
          Hefty.pure(42)
        end

      assert %Hefty.Pure{val: 42} = result
    end

    test "single bind" do
      result =
        hefty do
          x <- Hefty.pure(5)
          Hefty.pure(x * 2)
        end

      assert %Hefty.Pure{val: 10} = result
    end

    test "multiple binds" do
      result =
        hefty do
          x <- Hefty.pure(5)
          y <- Hefty.pure(3)
          z <- Hefty.pure(2)
          Hefty.pure(x + y + z)
        end

      assert %Hefty.Pure{val: 10} = result
    end

    test "regular assignment with =" do
      result =
        hefty do
          x <- Hefty.pure(5)
          y = 10
          z = x + y
          Hefty.pure(z)
        end

      assert %Hefty.Pure{val: 15} = result
    end

    test "mixed binds and assignments" do
      result =
        hefty do
          x <- Hefty.pure(5)
          y = 10
          z <- Hefty.pure(3)
          total = x + y + z
          Hefty.pure(total)
        end

      assert %Hefty.Pure{val: 18} = result
    end

    test "return/1 is imported from Hefty" do
      result =
        hefty do
          x <- Hefty.pure(42)
          # This is Hefty.return
          return(x)
        end

      assert %Hefty.Pure{val: 42} = result
    end
  end

  describe "hefty macro - auto-lifting Freer" do
    test "auto-lifts Freer.Pure" do
      result =
        hefty do
          # Freer - auto-lifted!
          x <- Freyja.Freer.pure(42)
          Hefty.pure(x)
        end

      # Freer.Pure binding applies continuation immediately, so result is Pure
      assert %Hefty.Pure{val: 42} = result
    end

    test "auto-lifts Freer effect (State.get)" do
      result =
        hefty do
          # Returns Freer.Impure - auto-lifted!
          x <- State.get()
          Hefty.pure(x)
        end

      # Should have Lift wrapping State.get
      assert %Hefty.Impure{} = result
    end

    test "chains multiple Freer effects" do
      result =
        hefty do
          # Freer - auto-lifted
          x <- State.get()
          # Freer - auto-lifted
          _ <- State.put(x + 1)
          # Freer - auto-lifted
          y <- State.get()
          Hefty.pure(y)
        end

      # Should build Hefty tree with Lifts
      assert %Hefty.Impure{} = result
    end

    test "mixes Freer and Hefty seamlessly" do
      result =
        hefty do
          # Freer - auto-lifted
          x <- State.get()

          y <-
            Catch.catch_hefty(
              Hefty.pure(10),
              fn _err -> Hefty.pure(0) end
            )

          # Hefty - stays as-is
          # Freer - auto-lifted
          _z <- State.put(x + y)
          Hefty.pure(x + y)
        end

      assert %Hefty.Impure{} = result
    end
  end

  describe "hefty macro - execution" do
    test "executes pure computation" do
      computation =
        hefty do
          x <- Hefty.pure(5)
          y <- Hefty.pure(10)
          Hefty.pure(x + y)
        end

      outcome = HeftyRun.run_simple(computation, [])

      assert %OkResult{value: 15} = outcome.result
    end

    test "executes with auto-lifted State" do
      computation =
        hefty do
          # Auto-lifted
          x <- State.get()
          Hefty.pure(x * 2)
        end

      outcome =
        HeftyRun.run(
          computation,
          [Lift.Algebra],
          [State.Handler],
          %{State.Handler => 21}
        )

      assert %OkResult{value: 42} = outcome.result
    end

    test "executes with Catch and auto-lifted effects" do
      computation =
        hefty do
          result <-
            Catch.catch_hefty(
              hefty do
                # Auto-lifted
                x <- State.get()

                if x < 0 do
                  # Freer - auto-lifted
                  HeftyError.throw_error("negative")
                else
                  Hefty.pure(x * 2)
                end
              end,
              fn _err -> Hefty.pure(0) end
            )

          Hefty.pure(result)
        end

      # With positive state
      outcome1 =
        HeftyRun.run(
          computation,
          [Catch.Algebra, Lift.Algebra],
          [State.Handler, HeftyErrorHandler, Catch.RunCatchingHandler],
          %{State.Handler => 5}
        )

      assert %OkResult{value: 10} = outcome1.result

      # With negative state
      outcome2 =
        HeftyRun.run(
          computation,
          [Catch.Algebra, Lift.Algebra],
          [State.Handler, HeftyErrorHandler, Catch.RunCatchingHandler],
          %{State.Handler => -3}
        )

      assert %OkResult{value: 0} = outcome2.result
    end
  end

  describe "defhefty macro" do
    defhefty simple_function(x) do
      y <- Hefty.pure(x + 1)
      Hefty.pure(y * 2)
    end

    test "creates function returning Hefty" do
      result = simple_function(5)

      assert %Hefty.Pure{val: 12} = result
    end

    defhefty with_state(initial) do
      # Auto-lifted Freer
      State.put(initial)
      # Auto-lifted Freer
      x <- State.get()
      Hefty.pure(x)
    end

    test "function with auto-lifted Freer effects" do
      result = with_state(100)

      # Should create Hefty with Lifts
      assert %Hefty.Impure{} = result
    end

    defhefty with_catch(value) do
      result <-
        Catch.catch_hefty(
          hefty do
            if value < 0 do
              HeftyError.throw_error("negative")
            else
              Hefty.pure(value * 2)
            end
          end,
          fn _err -> Hefty.pure(0) end
        )

      Hefty.pure(result)
    end

    test "function with Catch higher-order effect" do
      # Success case
      result1 = with_catch(5)

      outcome1 =
        HeftyRun.run(
          result1,
          [Catch.Algebra, Lift.Algebra],
          [HeftyErrorHandler, Catch.RunCatchingHandler]
        )

      assert %OkResult{value: 10} = outcome1.result

      # Error case
      result2 = with_catch(-3)

      outcome2 =
        HeftyRun.run(
          result2,
          [Catch.Algebra, Lift.Algebra],
          [HeftyErrorHandler, Catch.RunCatchingHandler]
        )

      assert %OkResult{value: 0} = outcome2.result
    end
  end

  describe "defheftyp macro" do
    defheftyp private_helper(x) do
      y <- Hefty.pure(x + 1)
      Hefty.pure(y * 2)
    end

    defhefty public_function(x) do
      result <- private_helper(x)
      Hefty.pure(result + 100)
    end

    test "creates private function" do
      # Can't call private_helper directly from outside module
      # But can use via public function
      result = public_function(5)

      assert %Hefty.Pure{val: 112} = result
    end
  end

  describe "hefty macro - error cases" do
    test "using unsupported type in bind raises ISendable error" do
      # Delegates to ISendable.Any which gives helpful error
      assert_raise ArgumentError, ~r/not Sendable.*do you need to return/, fn ->
        Hefty.bind(:not_a_computation, fn x -> Hefty.pure(x) end)
      end
    end

    test "helpful error when struct doesn't implement ISendable" do
      error =
        assert_raise ArgumentError, fn ->
          Hefty.bind(%CustomStruct{value: 42}, fn x -> Hefty.pure(x) end)
        end

      assert error.message =~ "not Sendable"
      assert error.message =~ "do you need to return()"
    end
  end

  describe "hefty macro - catch clause" do
    test "catch clause with single pattern" do
      computation =
        hefty do
          x <- State.get()

          if x < 0 do
            HeftyError.throw_error("negative")
          else
            Hefty.pure(x * 2)
          end
        catch
          "negative" -> return(0)
        end

      # Test success case (no error)
      outcome1 =
        HeftyRun.run(
          computation,
          [Catch.Algebra, Lift.Algebra],
          [State.Handler, HeftyErrorHandler, Catch.RunCatchingHandler],
          %{State.Handler => 5}
        )

      assert %OkResult{value: 10} = outcome1.result

      # Test error case (caught)
      outcome2 =
        HeftyRun.run(
          computation,
          [Catch.Algebra, Lift.Algebra],
          [State.Handler, HeftyErrorHandler, Catch.RunCatchingHandler],
          %{State.Handler => -3}
        )

      assert %OkResult{value: 0} = outcome2.result
    end

    test "catch clause with multiple patterns" do
      computation =
        hefty do
          error_type <- State.get()

          case error_type do
            :throw_negative -> HeftyError.throw_error("negative")
            :throw_overflow -> HeftyError.throw_error("overflow")
            value -> return(value)
          end
        catch
          "negative" -> return(:handled_negative)
          "overflow" -> return(:handled_overflow)
        end

      # Test negative error
      outcome1 =
        HeftyRun.run(
          computation,
          [Catch.Algebra, Lift.Algebra],
          [State.Handler, HeftyErrorHandler, Catch.RunCatchingHandler],
          %{State.Handler => :throw_negative}
        )

      assert %OkResult{value: :handled_negative} = outcome1.result

      # Test overflow error
      outcome2 =
        HeftyRun.run(
          computation,
          [Catch.Algebra, Lift.Algebra],
          [State.Handler, HeftyErrorHandler, Catch.RunCatchingHandler],
          %{State.Handler => :throw_overflow}
        )

      assert %OkResult{value: :handled_overflow} = outcome2.result

      # Test success case
      outcome3 =
        HeftyRun.run(
          computation,
          [Catch.Algebra, Lift.Algebra],
          [State.Handler, HeftyErrorHandler, Catch.RunCatchingHandler],
          %{State.Handler => 42}
        )

      assert %OkResult{value: 42} = outcome3.result
    end

    test "catch clause with variable pattern (catch-all)" do
      computation =
        hefty do
          State.put(100)
          HeftyError.throw_error("any error")
        catch
          error -> return({:caught, error})
        end

      outcome =
        HeftyRun.run(
          computation,
          [Catch.Algebra, Lift.Algebra],
          [State.Handler, HeftyErrorHandler, Catch.RunCatchingHandler],
          %{State.Handler => 0}
        )

      assert %OkResult{value: {:caught, "any error"}} = outcome.result
    end

    test "catch clause re-throws unmatched errors" do
      computation =
        hefty do
          HeftyError.throw_error("unhandled")
        catch
          "handled" -> return(:ok)
        end

      outcome =
        HeftyRun.run(
          computation,
          [Catch.Algebra, Lift.Algebra],
          [State.Handler, HeftyErrorHandler, Catch.RunCatchingHandler],
          %{State.Handler => 0}
        )

      # Should propagate error since "unhandled" doesn't match "handled"
      assert %Freyja.ErrorResult{error: "unhandled"} = outcome.result
    end

    test "catch clause with bindings in try block" do
      computation =
        hefty do
          x <- State.get()
          y <- Hefty.pure(10)

          if x < 0 do
            HeftyError.throw_error({:negative, x})
          else
            return(x + y)
          end
        catch
          {:negative, value} -> return({:handled, value})
        end

      outcome =
        HeftyRun.run(
          computation,
          [Catch.Algebra, Lift.Algebra],
          [State.Handler, HeftyErrorHandler, Catch.RunCatchingHandler],
          %{State.Handler => -5}
        )

      assert %OkResult{value: {:handled, -5}} = outcome.result
    end
  end

  describe "defhefty macro - with catch clause" do
    defhefty safe_divide(a, b) do
      if b == 0 do
        HeftyError.throw_error(:division_by_zero)
      else
        return(div(a, b))
      end
    catch
      :division_by_zero -> return(:infinity)
    end

    test "function with catch clause handles errors" do
      # Success case
      result1 = safe_divide(10, 2)

      outcome1 =
        HeftyRun.run(
          result1,
          [Catch.Algebra, Lift.Algebra],
          [HeftyErrorHandler, Catch.RunCatchingHandler]
        )

      assert %OkResult{value: 5} = outcome1.result

      # Error case
      result2 = safe_divide(10, 0)

      outcome2 =
        HeftyRun.run(
          result2,
          [Catch.Algebra, Lift.Algebra],
          [HeftyErrorHandler, Catch.RunCatchingHandler]
        )

      assert %OkResult{value: :infinity} = outcome2.result
    end
  end

  describe "defheftyp macro - with catch clause" do
    defheftyp private_safe_operation(value) do
      if value < 0 do
        HeftyError.throw_error(:invalid_value)
      else
        return(value * 2)
      end
    catch
      :invalid_value -> return(0)
    end

    defhefty public_wrapper(value) do
      result <- private_safe_operation(value)
      return(result + 100)
    end

    test "private function with catch clause" do
      result = public_wrapper(-5)

      outcome =
        HeftyRun.run(
          result,
          [Catch.Algebra, Lift.Algebra],
          [HeftyErrorHandler, Catch.RunCatchingHandler]
        )

      assert %OkResult{value: 100} = outcome.result
    end
  end
end
