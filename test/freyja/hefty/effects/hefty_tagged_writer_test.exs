defmodule Freyja.Hefty.Effects.HeftyTaggedWriterTest do
  use ExUnit.Case, async: true

  @moduledoc """
  Tests for HeftyTaggedWriter - Hefty implementation of listen operation.

  Demonstrates migrating a scoped effect (listen) from the old scoped handler
  approach to clean Hefty elaboration.
  """

  import Freyja.HeftyMacro

  alias Freyja.Run
  alias Freyja.Effects.TaggedWriter
  alias Freyja.Effects.Lift

  describe "listen/1 - basic functionality" do
    test "captures logs from inner computation" do
      computation =
        TaggedWriter.listen(
          hefty do
            _ <- TaggedWriter.tell(:audit, "event 1")
            _ <- TaggedWriter.tell(:audit, "event 2")
            return(:ok)
          end
        )

      outcome =
        Run.run(
          computation,
          [TaggedWriter.Algebra, Lift.Algebra],
          [TaggedWriter.Handler],
          %{TaggedWriter.Handler => %{}}
        )

      assert {:ok, captured} = outcome.result
      assert captured[:audit] == ["event 2", "event 1"]
    end

    test "captures logs from multiple tags" do
      computation =
        TaggedWriter.listen(
          hefty do
            _ <- TaggedWriter.tell(:audit, "audit 1")
            _ <- TaggedWriter.tell(:debug, "debug 1")
            _ <- TaggedWriter.tell(:audit, "audit 2")
            return(42)
          end
        )

      outcome =
        Run.run(
          computation,
          [TaggedWriter.Algebra, Lift.Algebra],
          [TaggedWriter.Handler],
          %{TaggedWriter.Handler => %{}}
        )

      assert {42, captured} = outcome.result
      assert captured[:audit] == ["audit 2", "audit 1"]
      assert captured[:debug] == ["debug 1"]
    end

    test "empty computation captures no logs" do
      computation =
        TaggedWriter.listen(
          hefty do
            return(:done)
          end
        )

      outcome =
        Run.run(
          computation,
          [TaggedWriter.Algebra, Lift.Algebra],
          [TaggedWriter.Handler],
          %{TaggedWriter.Handler => %{}}
        )

      assert {:done, captured} = outcome.result
      assert captured == %{}
    end

    test "logs written inside listen also appear in outer state" do
      computation =
        hefty do
          _ <- TaggedWriter.tell(:audit, "before")

          {_result, captured} <-
            TaggedWriter.listen(
              hefty do
                _ <- TaggedWriter.tell(:audit, "inner")
                return(:ok)
              end
            )

          # After listen, outer state should have both logs
          all_logs <- TaggedWriter.peek(:audit)
          return({captured, all_logs})
        end

      outcome =
        Run.run(
          computation,
          [TaggedWriter.Algebra, Lift.Algebra],
          [TaggedWriter.Handler],
          %{TaggedWriter.Handler => %{}}
        )

      assert {captured, all_logs} = outcome.result
      # Captured only has the inner log
      assert captured[:audit] == ["inner"]
      # All logs has both (reverse chronological)
      assert all_logs == ["inner", "before"]
    end
  end

  describe "listen/1 - nested listen" do
    test "nested listen scopes work correctly" do
      computation =
        hefty do
          _ <- TaggedWriter.tell(:audit, "outer 1")

          {_r1, outer_captured} <-
            TaggedWriter.listen(
              hefty do
                _ <- TaggedWriter.tell(:audit, "middle 1")

                {_r2, inner_captured} <-
                  TaggedWriter.listen(
                    hefty do
                      _ <- TaggedWriter.tell(:audit, "inner 1")
                      _ <- TaggedWriter.tell(:audit, "inner 2")
                      return(:inner_done)
                    end
                  )

                _ <- TaggedWriter.tell(:audit, "middle 2")
                return({:middle_done, inner_captured})
              end
            )

          _ <- TaggedWriter.tell(:audit, "outer 2")
          return(outer_captured)
        end

      outcome =
        Run.run(
          computation,
          [TaggedWriter.Algebra, Lift.Algebra],
          [TaggedWriter.Handler],
          %{TaggedWriter.Handler => %{}}
        )

      assert outer_captured = outcome.result
      # Outer captured should have middle 1, inner 1, inner 2, middle 2
      assert outer_captured[:audit] == ["middle 2", "inner 2", "inner 1", "middle 1"]

      # Final state should have all logs
      assert outcome.outputs[TaggedWriter.Handler][:audit] == [
               "outer 2",
               "middle 2",
               "inner 2",
               "inner 1",
               "middle 1",
               "outer 1"
             ]
    end
  end
end
