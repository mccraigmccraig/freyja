defmodule Freyja.Effects.Bracket do
  @moduledoc """
  Higher-order Bracket effect for safe resource acquisition and cleanup.

  Bracket ensures that resources are properly released even when errors occur
  or computations suspend. This is essential for managing resources like file
  handles, database connections, locks, and network connections.

  ## Overview

  The Bracket effect provides the `bracket/3` operation that takes three arguments:
  - `acquire` - Hefty computation that acquires a resource
  - `release_fn` - Function `(resource -> Hefty.t())` that releases the resource
  - `use_fn` - Function `(resource -> Hefty.t())` that uses the resource

  The release function is guaranteed to run exactly once, whether the use
  computation succeeds, throws an error, or suspends and later resumes.

  ## Example

      result <- Bracket.bracket(
        hefty do
          # Acquire resource
          handle <- FileSystem.open("file.txt")
          return(handle)
        end,
        fn handle ->
          # Release (always runs)
          hefty do
            FileSystem.close(handle)
            return(:ok)
          end
        end,
        fn handle ->
          # Use resource
          hefty do
            content <- FileSystem.read(handle)
            return(process(content))
          end
        end
      )

  ## Error Handling

  If the use computation throws an error, the release function runs before
  the error is re-thrown:

      result <- Bracket.bracket(
        acquire_connection(),
        fn conn -> release_connection(conn) end,
        fn conn ->
          hefty do
            # If this throws, conn is still released
            result <- dangerous_operation(conn)
            return(result)
          end
        end
      )

  ## Suspensions

  Bracket works correctly with suspensions (like Coroutine.yield). The release
  is structurally part of the continuation, so it runs after the computation
  resumes and completes.

  ## Nested Brackets

  Brackets can be nested. Each bracket manages its own resource independently:

      outer_result <- Bracket.bracket(
        acquire_outer(),
        fn outer -> release_outer(outer) end,
        fn outer ->
          hefty do
            inner_result <- Bracket.bracket(
              acquire_inner(),
              fn inner -> release_inner(inner) end,
              fn inner -> use_both(outer, inner) end
            )
            return(inner_result)
          end
        end
      )

  Resources are released in LIFO order (inner first, then outer).
  """

  import Freyja.Hefty.Sig.DefHeftyStruct

  def_hefty_struct(Bracket, release_fn: nil, use_fn: nil)

  @doc """
  Acquire a resource, use it, and ensure it is released.

  The release function is guaranteed to run exactly once, whether the use
  computation succeeds or throws an error.

  ## Parameters

  - `acquire_comp` - Hefty computation that acquires a resource
  - `release_fn` - Function `(resource -> Hefty.t())` that releases the resource
  - `use_fn` - Function `(resource -> Hefty.t())` that uses the resource

  ## Returns

  A Hefty computation that returns the result of the use function.

  ## Example

      result <- Bracket.bracket(
        hefty do
          Logger.info("Acquiring lock")
          Lock.acquire(:my_lock)
        end,
        fn lock ->
          hefty do
            Logger.info("Releasing lock")
            Lock.release(lock)
          end
        end,
        fn lock ->
          hefty do
            # Critical section - lock is held
            result <- do_work()
            return(result)
          end
        end
      )
  """
  def bracket(acquire_comp, release_fn, use_fn)
      when is_function(release_fn, 1) and is_function(use_fn, 1) do
    Freyja.Hefty.send_hefty(
      __MODULE__,
      %Bracket{release_fn: release_fn, use_fn: use_fn},
      %{acquire: acquire_comp}
    )
  end
end

defmodule Freyja.Effects.Bracket.Algebra do
  @moduledoc """
  Algebra for elaborating Bracket operations.

  ## Overview

  The Bracket algebra ensures that resources are properly released by
  elaborating to a combination of the Catch effect and strategic placement
  of release calls.

  ## Elaboration Strategy

  The key insight is that release must be called in BOTH success and error paths:

  1. **Success path**: acquire → use → release → return result
  2. **Error path**: acquire → use (errors) → release → re-throw error

  We achieve this by placing the release call:
  - Inside the try block (runs after successful use)
  - Inside the catch block (runs before re-throwing error)

  This ensures release runs exactly once on either path.

  ## Correctness

  **Why not run release after catch?**

  If we ran release after the catch operation completes, it would:
  - Run twice on success (once in try block, once after catch)
  - Not run on error (catch re-throws before exiting)

  **Why use Catch instead of a custom runner?**

  The Catch effect already handles:
  - Error propagation
  - Suspension preservation across error boundaries
  - State propagation

  By reusing Catch, we get these features for free.

  ## Suspension Handling

  When a suspension occurs in the use block, the continuation includes the
  release call because it's structurally part of the elaborated computation.
  When the computation resumes and completes (successfully or with error),
  the release runs.

  ## Example Elaboration

  Input Hefty:
      Bracket.bracket(
        open_file(),
        fn h -> close_file(h) end,
        fn h -> read_file(h) end
      )

  Elaborated Freer (conceptual):
      con do
        resource <- open_file()  # Already Freer

        result <- Catch.catch_hefty(
          hefty do
            # Success path
            result <- read_file(resource)
            _ <- close_file(resource)  # Release on success
            return(result)
          end,
          fn err ->
            # Error path
            hefty do
              _ <- close_file(resource)  # Release on error
              Lift.lift(Throw.throw_error(err))  # Re-throw
            end
          end
        )

        continuation.(result)
      end
  """

  @behaviour Freyja.Hefty.Algebra

  import Freyja.Hefty.HeftyBlock

  alias Freyja.Effects.Bracket
  alias Freyja.Effects.Bracket.Bracket, as: BracketOp
  alias Freyja.Effects.Catch
  alias Freyja.Effects.Lift
  alias Freyja.Effects.Throw
  alias Freyja.Freer

  @impl true
  def handles_hefty?(sig) when sig == Bracket, do: true
  def handles_hefty?(_), do: false

  @impl true
  def elaborate(%BracketOp{release_fn: release_fn, use_fn: use_fn} = _op, psi, k, elaborator) do
    # Extract the already-elaborated acquire computation (Freer)
    acquire_comp = Map.fetch!(psi, :acquire)

    # Build a Hefty computation that uses Catch to ensure release runs
    hefty_comp =
      hefty do
        # Lift the acquire from Freer to Hefty
        resource <- Lift.lift(acquire_comp)

        # Use Catch to ensure release runs on both success and error paths
        result <-
          Catch.catch_hefty(
            # Success path: use then release
            hefty do
              result <- use_fn.(resource)
              _unit <- release_fn.(resource)
              return(result)
            end,
            # Error path: release then re-throw
            fn err ->
              hefty do
                _unit <- release_fn.(resource)
                Lift.lift(Throw.throw_error(err))
              end
            end
          )

        return(result)
      end

    # Elaborate the Hefty computation to Freer using the provided elaborator
    freer_comp = elaborator.(hefty_comp)

    # Bind the elaborated computation to the outer continuation
    Freer.bind(freer_comp, k)
  end

  @doc """
  Add this algebra to a computation or builder pipeline.

  ## Examples

      # Start new pipeline
      hefty_computation |> Bracket.Algebra.run()

      # Add to existing pipeline
      builder |> Bracket.Algebra.run()
  """
  def run(computation_or_builder) do
    Freyja.Run.RunBuilder.add(computation_or_builder, __MODULE__, nil)
  end
end
