defmodule Freyja.ConElseErrorTest do
  use ExUnit.Case

  alias Freyja.Effects.Writer
  alias Freyja.Hefty
  alias Freyja.Hefty.Effects.{Lift, HeftyError}
  alias Freyja.Effects.Catch

  describe "hefty ... catch error handling" do
    test "matches a pattern and recovers" do
      import Freyja.HeftyMacro

      fv = hefty do
        Lift.lift(HeftyError.throw_error({:invalid, 3}))
        return(:unreachable)
      catch
        {:invalid, n} -> return({:fixed, n + 1})
      end

      algebras = [Lift.Algebra, Catch.Algebra]
      handlers = [HeftyError.Handler, Catch.RunCatchingHandler]
      initial_states = %{}

      %Freyja.RunOutcome{result: res, outputs: _out} = Hefty.Run.run(fv, algebras, handlers, initial_states)

      assert Freyja.Protocols.Result.type(res) == Freyja.OkResult
      assert Freyja.Protocols.Result.value(res) == {:fixed, 4}
    end

    test "no matching clause rethrows" do
      import Freyja.HeftyMacro

      fv = hefty do
        Lift.lift(HeftyError.throw_error(:nope))
        return(:unreachable)
      catch
        :other -> return(:ok)
      end

      algebras = [Lift.Algebra, Catch.Algebra]
      handlers = [HeftyError.Handler, Catch.RunCatchingHandler]
      initial_states = %{}

      %Freyja.RunOutcome{result: res} = Hefty.Run.run(fv, algebras, handlers, initial_states)
      assert Freyja.Protocols.Result.type(res) == Freyja.ErrorResult
      assert Freyja.Protocols.Result.value(res) == :nope
    end

    test "handler clause can perform effects" do
      import Freyja.HeftyMacro

      fv = hefty do
        Lift.lift(HeftyError.throw_error(:bad))
        return(:nope)
      catch
        :bad ->
          Writer.tell({:handled, :bad})
          return(:ok)
      end

      algebras = [Lift.Algebra, Catch.Algebra]
      handlers = [HeftyError.Handler, Catch.RunCatchingHandler, Writer.Handler]
      initial_states = %{}

      %Freyja.RunOutcome{result: res, outputs: out} = Hefty.Run.run(fv, algebras, handlers, initial_states)

      assert Freyja.Protocols.Result.type(res) == Freyja.OkResult
      assert Freyja.Protocols.Result.value(res) == :ok
      # Writer output is in reverse order (most recent first)
      assert out[Writer.Handler] == [{:handled, :bad}]
    end

    test "user-supplied default catch clause handles all and prevents rethrow" do
      import Freyja.HeftyMacro

      fv = hefty do
        Lift.lift(HeftyError.throw_error(:anything))
        return(:unreachable)
      catch
        _ -> return(:handled)
      end

      algebras = [Lift.Algebra, Catch.Algebra]
      handlers = [HeftyError.Handler, Catch.RunCatchingHandler]
      initial_states = %{}

      %Freyja.RunOutcome{result: res, outputs: _out} = Hefty.Run.run(fv, algebras, handlers, initial_states)

      assert Freyja.Protocols.Result.type(res) == Freyja.OkResult
      assert Freyja.Protocols.Result.value(res) == :handled
    end
  end
end
