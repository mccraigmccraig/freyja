defmodule Skuld.Effects.YieldTest do
  use ExUnit.Case, async: true

  alias Skuld.Comp
  alias Skuld.Effects.Yield

  describe "yield" do
    test "suspends computation" do
      comp = Yield.yield(:hello)

      {result, _env} =
        comp
        |> Yield.with_handler()
        |> Comp.run()

      assert %Comp.Suspend{value: :hello, resume: resume} = result
      assert is_function(resume, 1)
    end

    test "resume continues computation" do
      comp =
        Comp.bind(Yield.yield(:first), fn x ->
          Comp.pure({:got, x})
        end)

      {%Comp.Suspend{value: :first, resume: resume}, _suspended_env} =
        comp
        |> Yield.with_handler()
        |> Comp.run()

      assert {{:got, :input_value}, _} = resume.(:input_value)
    end

    test "multiple yields" do
      comp =
        Comp.bind(Yield.yield(1), fn a ->
          Comp.bind(Yield.yield(2), fn b ->
            Comp.bind(Yield.yield(3), fn c ->
              Comp.pure(a + b + c)
            end)
          end)
        end)

      {%Comp.Suspend{value: 1, resume: r1}, _e1} =
        comp
        |> Yield.with_handler()
        |> Comp.run()

      {%Comp.Suspend{value: 2, resume: r2}, _e2} = r1.(10)
      {%Comp.Suspend{value: 3, resume: r3}, _e3} = r2.(20)
      # 10 + 20 + 30
      {60, _} = r3.(30)
    end
  end

  describe "collect" do
    test "gathers all yields" do
      comp =
        Comp.bind(Yield.yield(:a), fn _ ->
          Comp.bind(Yield.yield(:b), fn _ ->
            Comp.bind(Yield.yield(:c), fn _ ->
              Comp.pure(:done)
            end)
          end)
        end)
        |> Yield.with_handler()

      assert {:done, :done, [:a, :b, :c], _} = Yield.collect(comp)
    end
  end

  describe "feed" do
    test "provides inputs to yields" do
      comp =
        Comp.bind(Yield.yield(:want_x), fn x ->
          Comp.bind(Yield.yield(:want_y), fn y ->
            Comp.pure(x * y)
          end)
        end)
        |> Yield.with_handler()

      assert {:done, 12, [:want_x, :want_y], _} = Yield.feed(comp, [3, 4])
    end

    test "stops when inputs exhausted" do
      comp =
        Comp.bind(Yield.yield(1), fn _ ->
          Comp.bind(Yield.yield(2), fn _ ->
            Comp.bind(Yield.yield(3), fn _ ->
              Comp.pure(:done)
            end)
          end)
        end)
        |> Yield.with_handler()

      {:suspended, 2, _resume, [1], _env} = Yield.feed(comp, [:a])
    end
  end
end
