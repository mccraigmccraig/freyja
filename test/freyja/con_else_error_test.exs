defmodule Freyja.ConElseErrorTest do
  use ExUnit.Case

  alias Freyja.Effects.Error
  alias Freyja.Effects.Writer
  alias Freyja.Run

  describe "con ... else error handling" do
    test "matches a pattern and recovers" do
      import Freyja.Con

      fv =
        con [Error] do
          throw_fx({:invalid, 3})
          return(:unreachable)
        catch
          {:invalid, n} -> return({:fixed, n + 1})
        end

      runner = Run.with_handlers(e: Error.Handler)

      %Freyja.RunOutcome{result: res, outputs: _out} = Run.run(fv, runner)

      assert Freyja.Protocols.Result.type(res) == Freyja.OkResult
      assert Freyja.Protocols.Result.value(res) == {:fixed, 4}
    end

    test "no matching clause rethrows" do
      import Freyja.Con

      fv =
        con [Error] do
          _ <- throw_fx(:nope)
          return(:unreachable)
        catch
          :other -> return(:ok)
        end

      runner = Run.with_handlers(e: Error.Handler)

      %Freyja.RunOutcome{result: res} = Run.run(fv, runner)
      assert Freyja.Protocols.Result.type(res) == Freyja.ErrorResult
      assert Freyja.Protocols.Result.value(res) == :nope
    end

    test "handler clause can perform effects" do
      import Freyja.Con

      fv =
        con [Error, Writer] do
          _ <- tell(:before)
          _ <- throw_fx(:bad)
          _ <- tell(:after)
          return(:nope)
        catch
          :bad ->
            _ <- tell({:handled, :bad})
            return(:ok)
        end

      runner =
        Run.with_handlers(
          e: Error.Handler,
          w: Writer.Handler
        )

      %Freyja.RunOutcome{result: res, outputs: out} = Run.run(fv, runner)

      assert Freyja.Protocols.Result.type(res) == Freyja.OkResult
      assert Freyja.Protocols.Result.value(res) == :ok
      # Writer output is in reverse order (most recent first)
      assert out.w == [{:handled, :bad}, :before]
    end

    test "user-supplied default else clause handles all and prevents rethrow" do
      import Freyja.Con

      fv =
        con [Error] do
          _ <- throw_fx(:anything)
          return(:unreachable)
        catch
          _ -> return(:handled)
        end

      runner =
        Run.with_handlers(e: Error.Handler)

      %Freyja.RunOutcome{result: res, outputs: _out} = Run.run(fv, runner)

      assert Freyja.Protocols.Result.type(res) == Freyja.OkResult
      assert Freyja.Protocols.Result.value(res) == :handled
    end
  end
end
