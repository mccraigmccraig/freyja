defmodule Freyja.ConElseErrorTest do
  use ExUnit.Case

  alias Freyja.Effects.Writer
  alias Freyja.Run
  alias Freyja.Effects.{Lift, Throw}
  alias Freyja.Effects.Catch

  describe "hefty ... catch error handling" do
    test "matches a pattern and recovers" do
      use Freyja.Syntax

      fv =
        hefty do
          _ <- Lift.lift(Throw.throw_error({:invalid, 3}))
          return(:unreachable)
        catch
          {:invalid, n} -> return({:fixed, n + 1})
        end

      %Freyja.Run.RunOutcome{result: res, outputs: _out} =
        fv
        |> Catch.Algebra.run()
        |> Lift.Algebra.run()
        |> Throw.Handler.run()
        |> Run.run()

      assert res == {:ok, {:fixed, 4}}
    end

    test "no matching clause rethrows" do
      use Freyja.Syntax

      fv =
        hefty do
          _ <- Lift.lift(Throw.throw_error(:nope))
          return(:unreachable)
        catch
          :other -> return(:ok)
        end

      %Freyja.Run.RunOutcome{result: res} =
        fv
        |> Catch.Algebra.run()
        |> Lift.Algebra.run()
        |> Throw.Handler.run()
        |> Run.run()

      assert res == {:error, :nope}
    end

    test "handler clause can perform effects" do
      use Freyja.Syntax

      fv =
        hefty do
          _ <- Lift.lift(Throw.throw_error(:bad))
          return(:nope)
        catch
          :bad ->
            _ <- Writer.tell({:handled, :bad})
            return(:ok)
        end

      %Freyja.Run.RunOutcome{result: res, outputs: out} =
        fv
        |> Catch.Algebra.run()
        |> Lift.Algebra.run()
        |> Throw.Handler.run()
        |> Writer.Handler.run()
        |> Run.run()

      assert res == {:ok, :ok}
      # Writer output is in reverse order (most recent first)
      assert out[Writer.Handler] == [{:handled, :bad}]
    end

    test "user-supplied default catch clause handles all and prevents rethrow" do
      use Freyja.Syntax

      fv =
        hefty do
          _ <- Lift.lift(Throw.throw_error(:anything))
          return(:unreachable)
        catch
          _ -> return(:handled)
        end

      %Freyja.Run.RunOutcome{result: res, outputs: _out} =
        fv
        |> Catch.Algebra.run()
        |> Lift.Algebra.run()
        |> Throw.Handler.run()
        |> Run.run()

      assert res == {:ok, :handled}
    end
  end
end
