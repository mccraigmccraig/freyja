defmodule Freyja.Hefty.Elaborate do
  @moduledoc """
  Catamorphism (fold) for elaborating Hefty trees into Freer computations.

  Based on "Hefty Algebras: Modular Elaboration of Higher-Order Algebraic Effects"
  (Poulsen & van der Rest, POPL 2023), Section 3.4.

  ## What is Elaboration?

  Elaboration transforms higher-order effects (operations that take computations
  as parameters) into first-order effects (basic operations). This is the first
  phase in the Hefty algebras pipeline:

      Hefty H A --elaborate--> Freer Δ A --interpret--> Result

  ## How Does It Work?

  The `elaborate/2` function is a **catamorphism** (fold) over Hefty trees that:

  1. Processes the tree **bottom-up** (leaves to root)
  2. At each `Impure` node:
     - Recursively elaborates all computation parameters (psi) first
     - Recursively elaborates the continuation
     - Calls the algebra with the **already-elaborated** parts
  3. At each `Pure` node:
     - Returns `Freer.pure(value)`

  ## Key Insight: Algebras Receive Already-Elaborated Sub-Computations

  This is the crucial point that makes algebras simple:

  When an algebra's `elaborate/4` is called, the computation parameters in `psi`
  are **not** Hefty trees anymore - they're Freer computations. The fold has
  already recursively transformed them.

  The algebra just needs to compose these Freer computations using first-order
  effects and normal control flow.

  ## Example Execution

      # Input Hefty tree
      Catch.catch(
        hefty do                    # try block (Hefty)
          x <- State.get()
          Hefty.pure(x * 2)
        end,
        Hefty.pure(0)              # catch block (Hefty)
      )

      # Elaboration process:
      # 1. Elaborate try block → Freer computation
      # 2. Elaborate catch block → Freer computation
      # 3. Call Catch.Algebra with elaborated Freer computations
      # 4. Algebra returns Freer with Error.catch_fx and case statement

      # Result: Freer computation
      con do
        result <- Error.catch_fx(
          con do                    # try block (now Freer)
            x <- State.get()
            Freer.pure(x * 2)
          end
        )
        case result do
          {:ok, value} -> Freer.pure(value)
          {:error, _} -> Freer.pure(0)  # catch block (now Freer)
        end
      end

  ## Algebra Composition

  Multiple algebras can be provided to handle different effect signatures:

      elaborate(hefty_tree, [
        Catch.Algebra,
        Local.Algebra,
        FxList.Algebra,
        Lift.Algebra
      ])

  The fold dispatches to the correct algebra based on the operation's signature.
  If no algebra handles a signature, an error is raised.

  ## Correspondence to Paper

  - **cata^H** - Our `elaborate/2` function
  - **pure** injection - Pure nodes become Freer.pure
  - **alg** application - Call algebra's elaborate/4
  - Bottom-up fold - Ensures algebras receive elaborated sub-computations

  ## See Also

  - `Freyja.Hefty.Algebra` - Behavior for algebras
  - `Freyja.Hefty` - Hefty tree data structure
  - `Freyja.Freer` - First-order effect trees (elaboration target)
  """

  alias Freyja.Hefty
  alias Freyja.Hefty.Pure
  alias Freyja.Hefty.Impure
  alias Freyja.Freer

  @doc """
  Elaborate a Hefty tree into a Freer computation using algebras.

  Applies a catamorphism (fold) over the Hefty tree, transforming
  higher-order operations into first-order effects.

  ## Parameters

  - `hefty_tree` - The Hefty computation to elaborate
  - `algebras` - List of algebra modules implementing `Freyja.Hefty.Algebra`

  ## Returns

  A `Freer.t()` computation with only first-order effects.

  ## Errors

  Raises `ArgumentError` if no algebra handles a signature encountered in the tree.

  ## Examples

      # Simple elaboration
      hefty_tree = Hefty.pure(42)
      freer = Elaborate.elaborate(hefty_tree, [])
      # => %Freer.Pure{val: 42}

      # With algebras
      hefty_tree = Catch.catch(
        Hefty.pure(42),
        Hefty.pure(0)
      )
      freer = Elaborate.elaborate(hefty_tree, [Catch.Algebra])
      # => Freer computation with Error.catch_fx

      # Multiple algebras
      Elaborate.elaborate(complex_hefty, [
        Catch.Algebra,
        Local.Algebra,
        FxList.Algebra
      ])

  ## How It Works

  The fold processes the tree bottom-up:

  1. **Pure nodes**: Return `Freer.pure(value)`
  2. **Impure nodes**:
     - Find algebra that handles the signature
     - Recursively elaborate all psi computations → Freer
     - Recursively elaborate continuation → Freer
     - Call algebra with elaborated parts
     - Return the algebra's Freer result

  The algebras receive computation parameters that are already Freer,
  so they just need to compose them.
  """
  @spec elaborate(Hefty.t(), [module]) :: Freer.t()
  def elaborate(hefty_tree, algebras) when is_list(algebras) do
    do_elaborate(hefty_tree, algebras)
  end

  # Base case: Pure nodes become Freer.pure
  defp do_elaborate(%Pure{val: x}, _algebras) do
    Freer.pure(x)
  end

  # Recursive case: Apply algebra to operation
  defp do_elaborate(%Impure{sig: sig, data: op, psi: psi, k: k}, algebras) do
    # Find algebra that handles this signature
    algebra = find_algebra(sig, algebras)

    # Recursively elaborate all computation parameters (bottom-up!)
    # psi is %{fork_key => Hefty} → transform to %{fork_key => Freer}
    # Computation parameters might be bare sendable structs, so convert first
    elaborated_psi =
      Map.new(psi, fn {key, comp} ->
        # Convert to Hefty if needed (handles bare structs)
        hefty_comp =
          case comp do
            %Hefty.Pure{} -> comp
            %Hefty.Impure{} -> comp
            other -> Freyja.Hefty.Sig.IHeftySendable.send_to_hefty(other)
          end

        {key, do_elaborate(hefty_comp, algebras)}
      end)

    # Recursively elaborate the continuation
    # k is (any -> Hefty) → transform to (any -> Freer)
    # The continuation might return bare sendable structs, so convert first
    elaborated_k = fn x ->
      result = k.(x)
      # Convert to Hefty if needed (handles bare structs)
      hefty_result =
        case result do
          %Hefty.Pure{} -> result
          %Hefty.Impure{} -> result
          other -> Freyja.Hefty.Sig.IHeftySendable.send_to_hefty(other)
        end

      do_elaborate(hefty_result, algebras)
    end

    # Now call the algebra with already-elaborated parts
    # The algebra receives Freer computations in psi and k,
    # and returns a Freer computation
    # The 4th parameter is an elaborator function for dynamic Hefty elaboration
    elaborator = fn hefty_comp -> do_elaborate(hefty_comp, algebras) end
    algebra.elaborate(op, elaborated_psi, elaborated_k, elaborator)
  end

  # Find algebra that handles the given signature
  defp find_algebra(sig, algebras) do
    case Enum.find(algebras, &algebra_handles_hefty?(&1, sig)) do
      nil ->
        raise ArgumentError, """
        No algebra found for signature: #{inspect(sig)}

        Available algebras: #{inspect(algebras)}

        Make sure you've provided an algebra that implements:
          @behaviour Freyja.Hefty.Algebra
          def handles_hefty?(#{inspect(sig)}), do: true

        Example:
          defmodule MyEffect.Algebra do
            @behaviour Freyja.Hefty.Algebra

            @impl true
            def handles_hefty?(#{inspect(sig)}), do: true
            def handles_hefty?(_), do: false

            @impl true
            def elaborate(operation, psi, k, _elaborator) do
              # Your elaboration logic here
            end
          end
        """

      algebra ->
        algebra
    end
  end

  # Check if algebra handles signature, with error handling
  defp algebra_handles_hefty?(algebra, sig) do
    try do
      algebra.handles_hefty?(sig)
    rescue
      UndefinedFunctionError ->
        # credo:disable-for-next-line Credo.Check.Warning.RaiseInsideRescue
        raise ArgumentError, """
        Module #{inspect(algebra)} does not implement Freyja.Hefty.Algebra.

        Make sure your algebra module has:
          @behaviour Freyja.Hefty.Algebra

          @impl true
          def handles_hefty?(sig), do: ...

          @impl true
          def elaborate(operation, psi, k, elaborator), do: ...
        """
    end
  end
end
