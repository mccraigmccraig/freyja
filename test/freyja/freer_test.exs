defmodule Freyja.FreerTest do
  use ExUnit.Case

  require Logger
  alias Freyja.Freer
  alias Freyja.Freer.{Pure, Impure}

  describe "pure" do
    test "it wraps a value" do
      assert %Pure{val: 10} === Freer.pure(10)
    end
  end

  describe "send" do
    test "it wraps values into the Freer Monad" do
      assert %Impure{sig: EffectMod, data: :val, q: [&Freer.pure/1]} ==
               Freer.send_effect(:val, EffectMod)
    end
  end

  describe "return" do
    test "it returns a value" do
      assert %Pure{val: 10} === Freer.return(10)
    end
  end

  describe "bind" do
    test "it binds a value" do
      assert %Impure{sig: EffectMod, data: 10, q: [pure_f, step_f]} =
               Freer.send_effect(10, EffectMod)
               |> Freer.bind(fn x -> Freer.return(2 * x) end)

      assert %Pure{val: 10} == pure_f.(10)
      assert %Pure{val: 20} == step_f.(10)
    end

    test "it binds repeatedly with pure expressions" do
      assert %Impure{sig: EffectMod, data: 10, q: [pure_f, step_1_f, step_2_f]} =
               Freer.send_effect(10, EffectMod)
               |> Freer.bind(fn x -> Freer.return(2 * x) end)
               |> Freer.bind(fn x -> Freer.return(5 + x) end)

      assert %Pure{val: 10} = pure_f.(10)
      assert %Pure{val: 20} = step_1_f.(10)
      assert %Pure{val: 25} = step_2_f.(20)
    end

    test "it binds repeatedly with impure expressions" do
      assert %Impure{sig: EffectMod, data: 10, q: [step_1, step_2, step_3]} =
               Freer.send_effect(10, EffectMod)
               |> Freer.bind(fn x ->
                 x |> Freer.send_effect(EffectMod) |> Freer.bind(fn y -> Freer.return(2 * y) end)
               end)
               |> Freer.bind(fn x ->
                 x |> Freer.send_effect(EffectMod) |> Freer.bind(fn y -> Freer.return(5 + y) end)
               end)

      # trace the steps manually, feeding values from one into the next - this
      # is exactly what an interpreter for the identity effect would do
      pure = &Freer.pure/1
      assert %Pure{val: 10} = step_1.(10)
      assert %Impure{sig: EffectMod, data: 10, q: [^pure, step_2_2]} = step_2.(10)
      assert %Pure{val: 20} = step_2_2.(10)
      assert %Impure{sig: EffectMod, data: 20, q: [^pure, step_3_2]} = step_3.(20)
      assert %Pure{val: 25} = step_3_2.(20)
    end
  end
end
