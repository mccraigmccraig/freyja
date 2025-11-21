defmodule Freyja.Hefty.Algebra do
  @moduledoc """
  Behavior for Hefty algebras - F-algebras over Hefty trees.

  Based on "Hefty Algebras: Modular Elaboration of Higher-Order Algebraic Effects"
  (Poulsen & van der Rest, POPL 2023), Section 3.4.

  ## What is a Hefty Algebra?

  A Hefty algebra (Alg^H in the paper) is an F-algebra that transforms
  higher-order operations into first-order effects. It receives:

  1. **operation** - The higher-order operation struct (e.g., %Catch{}, %Local{})
  2. **psi** - Computation parameters ALREADY elaborated to Freer
  3. **k** - Continuation ALREADY elaborated to Freer
  4. **elaborator** - The algebra module itself (for recursion if needed)

  The algebra returns a Freer computation that represents the operation's semantics
  using only first-order effects.

  ## Key Insight: Already-Elaborated Sub-Computations

  This is crucial: When your algebra's `elaborate/4` is called, the computation
  parameters in `psi` are **not** Hefty trees anymore - they're Freer computations.
  The catamorphism (fold) has already recursively elaborated them bottom-up.

  Your algebra just needs to compose these Freer computations with first-order
  effects and call the continuation.

  ## Example: Catch Algebra

      defmodule Catch.Algebra do
        @behaviour Freyja.Hefty.Algebra

        @impl true
        def handles?(:Catch), do: true
        def handles?(_), do: false

        @impl true
        def elaborate(%Catch{}, psi, k, _elaborator) do
          try_comp = Map.fetch!(psi, :try)     # Already Freer!
          catch_comp = Map.fetch!(psi, :catch) # Already Freer!

          # Compose with first-order effects
          con do
            result <- Error.catch_fx(try_comp)  # First-order runner
            case result do
              {:ok, value} -> k.(value)         # Continue with success
              {:error, _} -> catch_comp >>= k   # Run catch, then continue
            end
          end
        end
      end

  ## The Algebra Pattern

  Most algebras follow this pattern:

  1. Extract already-elaborated computations from `psi`
  2. Create first-order "runner" effects that execute those computations
  3. Sequence runners with other first-order effects
  4. Branch on results using normal Elixir control flow (case, if, etc.)
  5. Call continuation `k` with the final result

  The control flow decisions are encoded as ordinary code (case statements, etc.)
  in the returned Freer computation. These decisions happen during interpretation,
  not during elaboration.

  ## Composition

  Algebras compose automatically via the fold mechanism. Each algebra handles
  its own signature. The `handles?/1` callback determines which operations
  an algebra processes.

  Multiple algebras can be provided to `Hefty.Elaborate.elaborate/2`:

      Hefty.Elaborate.elaborate(hefty_tree, [
        Catch.Algebra,
        Local.Algebra,
        FxList.Algebra,
        Lift.Algebra
      ])

  The fold dispatches to the correct algebra based on the operation's signature.

  ## Correspondence to Paper

  - **Alg^H H F** - Our `@behaviour Freyja.Hefty.Algebra`
  - **alg** function - Our `elaborate/4` callback
  - **cata^H** - Implemented in `Freyja.Hefty.Elaborate`
  - **ψ** (psi) - Map of computation parameters (forks)
  - **k** - Continuation function

  ## See Also

  - `Freyja.Hefty.Elaborate` - The catamorphism that applies algebras
  - `Freyja.Hefty` - Hefty tree data structure
  """

  alias Freyja.Freer

  @doc """
  Check if this algebra handles operations with the given signature.

  The signature is the effect module atom (e.g., `:Catch`, `:Local`, `:FxMap`).

  This is used by the fold to dispatch operations to the correct algebra.

  ## Examples

      # Catch algebra only handles :Catch
      @impl true
      def handles?(:Catch), do: true
      def handles?(_), do: false

      # An algebra that handles multiple related operations
      @impl true
      def handles?(sig) when sig in [:FxMap, :FxReduce], do: true
      def handles?(_), do: false
  """
  @callback handles?(sig :: atom) :: boolean

  @doc """
  Elaborate a higher-order operation into a first-order (Freer) computation.

  ## Parameters

  - `operation` - The operation struct (e.g., %Catch{}, %Local{}, %FxMap{})
  - `psi` - Map of computation parameters (forks), ALREADY elaborated to Freer
  - `k` - Continuation function (result -> Freer), ALREADY elaborated
  - `elaborator` - The algebra module itself (for recursive elaboration if needed)

  ## Returns

  A `Freer.t()` computation that implements the operation's semantics using
  only first-order effects.

  ## Important: Sub-Computations are Already Freer

  When your `elaborate/4` is called:
  - All computations in `psi` have been elaborated to Freer (not Hefty anymore)
  - The continuation `k` expects Freer values
  - You just need to compose them with first-order effects

  The catamorphism handles the recursion - you only define what to do at one level.

  ## Example

      @impl true
      def elaborate(%Catch{}, psi, k, _elaborator) do
        # psi values are Freer, not Hefty!
        try_comp = Map.fetch!(psi, :try)
        catch_comp = Map.fetch!(psi, :catch)

        # Compose with first-order effects and control flow
        con do
          result <- Error.catch_fx(try_comp)

          case result do
            {:ok, value} -> k.(value)
            {:error, _} ->
              catch_result <- catch_comp
              k.(catch_result)
          end
        end
      end

  The returned Freer computation contains:
  - First-order effects (Error.catch_fx)
  - Normal control flow (case statement)
  - Continuation calls

  All of this will be interpreted later - elaboration just builds the structure.
  """
  @callback elaborate(
              operation :: struct,
              psi :: %{any => Freer.t()},
              k :: (any -> Freer.t()),
              elaborator :: (Hefty.t() -> Freer.t())
            ) :: Freer.t()
end
