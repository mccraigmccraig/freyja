defmodule Skuld.Effects.YieldTest do
  use ExUnit.Case, async: true

  alias Skuld.Comp
  alias Skuld.Env
  alias Skuld.Effects.Yield

  describe "yield" do
    test "suspends computation" do
      env = Env.new() |> Yield.handler()

      comp = Yield.yield(:hello)
      assert {%Comp.Suspend{value: :hello, resume: resume}, _env} = Comp.run(comp, env)
      assert is_function(resume, 1)
    end

    test "resume continues computation" do
      env = Env.new() |> Yield.handler()

      comp =
        Comp.bind(Yield.yield(:first), fn x ->
          Comp.pure({:got, x})
        end)

      {%Comp.Suspend{value: :first, resume: resume}, _suspended_env} = Comp.run(comp, env)
      assert {{:got, :input_value}, _} = resume.(:input_value)
    end

    test "multiple yields" do
      env = Env.new() |> Yield.handler()

      comp =
        Comp.bind(Yield.yield(1), fn a ->
          Comp.bind(Yield.yield(2), fn b ->
            Comp.bind(Yield.yield(3), fn c ->
              Comp.pure(a + b + c)
            end)
          end)
        end)

      {%Comp.Suspend{value: 1, resume: r1}, _e1} = Comp.run(comp, env)
      {%Comp.Suspend{value: 2, resume: r2}, _e2} = r1.(10)
      {%Comp.Suspend{value: 3, resume: r3}, _e3} = r2.(20)
      # 10 + 20 + 30
      {60, _} = r3.(30)
    end
  end

  describe "collect" do
    test "gathers all yields" do
      env = Env.new() |> Yield.handler()

      comp =
        Comp.bind(Yield.yield(:a), fn _ ->
          Comp.bind(Yield.yield(:b), fn _ ->
            Comp.bind(Yield.yield(:c), fn _ ->
              Comp.pure(:done)
            end)
          end)
        end)

      assert {:done, :done, [:a, :b, :c], _} = Yield.collect(comp, env)
    end
  end

  describe "feed" do
    test "provides inputs to yields" do
      env = Env.new() |> Yield.handler()

      comp =
        Comp.bind(Yield.yield(:want_x), fn x ->
          Comp.bind(Yield.yield(:want_y), fn y ->
            Comp.pure(x * y)
          end)
        end)

      assert {:done, 12, [:want_x, :want_y], _} = Yield.feed(comp, env, [3, 4])
    end

    test "stops when inputs exhausted" do
      env = Env.new() |> Yield.handler()

      comp =
        Comp.bind(Yield.yield(1), fn _ ->
          Comp.bind(Yield.yield(2), fn _ ->
            Comp.bind(Yield.yield(3), fn _ ->
              Comp.pure(:done)
            end)
          end)
        end)

      {:suspended, 2, _resume, [1], _env} = Yield.feed(comp, env, [:a])
    end
  end
end
