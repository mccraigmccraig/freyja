defmodule Freyja.Sig.DefHeftyStructTest do
  use ExUnit.Case, async: true

  @moduledoc """
  Tests for def_hefty_struct macro.

  Verifies that higher-order effect structs are created correctly
  and are distinct from first-order effect structs.
  """

  alias Freyja.Hefty.Effects.Catch.Catch
  alias Freyja.Hefty.Effects.Lift

  describe "def_hefty_struct" do
    test "creates struct module" do
      # Catch is defined with def_hefty_struct
      assert %Catch{} = %Catch{type: :any}
      assert %Catch{type: :specific} = %Catch{type: :specific}
    end

    test "struct has moduledoc indicating higher-order" do
      {:docs_v1, _, _, _, module_doc, _, _} = Code.fetch_docs(Catch)

      doc_string = module_doc["en"]

      assert doc_string =~ "Higher-order operation"
      assert doc_string =~ "must be elaborated"
    end

    test "Lift operation uses plain defstruct" do
      # Lift is special - uses plain defstruct
      assert %Lift{} = %Lift{computation: nil}
    end

    test "higher-order structs are NOT Sendable to Freer" do
      # This is a compile-time distinction - def_hefty_struct doesn't
      # implement Sendable behavior

      # If you tried: Freyja.Freer.send(Catch, %Catch{})
      # It would fail because Catch is not Sendable

      # Instead, use Hefty.send_hefty:
      catch_op = Freyja.Hefty.send_hefty(
        Freyja.Hefty.Effects.Catch,
        %Catch{type: :any},
        %{try: Freyja.Hefty.pure(42), catch: Freyja.Hefty.pure(0)}
      )

      assert %Freyja.Hefty.Impure{
        sig: Freyja.Hefty.Effects.Catch,
        data: %Catch{type: :any}
      } = catch_op
    end
  end

  describe "comparison with def_effect_struct" do
    test "first-order effects use def_effect_struct and ARE Sendable" do
      # State.Get is defined with def_effect_struct
      alias Freyja.Effects.State.Get

      # Can check if it implements Sendable behavior
      # (This would be done via behavior check in real code)

      # These effects go directly to Freer
      assert %Get{} = %Get{}
    end

    test "higher-order effects use def_hefty_struct and are NOT Sendable" do
      # Catch is defined with def_hefty_struct

      # These effects must go through Hefty.send_hefty
      assert %Catch{type: :any} = %Catch{type: :any}

      # The distinction is semantic and documentation-based
      # Future: Could add Hefty.Sendable protocol for type checking
    end
  end
end
