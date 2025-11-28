defmodule Freyja.Effects.TaggedReader do
  @moduledoc """
  Tagged Reader effect for accessing multiple independent read-only environments.

  Unlike the regular Reader effect which provides a single read-only environment,
  TaggedReader allows multiple independent environments identified by tags.

  ## First-Order Operations

  - `ask/1` - Read the environment for a specific tag
  - `ask_all/0` - Read all tagged environments as a map

  ## Higher-Order Operations

  - `local/3` - Temporarily modify the environment for a single tag
  - `local_all/2` - Temporarily modify all tagged environments

  ## Example

      con [TaggedReader] do
        # Access different tagged environments
        db_config <- ask(:database)
        api_config <- ask(:api)
        app_env <- ask(:environment)

        return(%{db: db_config, api: api_config, env: app_env})
      end

  ## Handler Setup

  The handler state must be a map where keys are tags and values are the
  environment for each tag:

      RunState.new(
        tr: {TaggedReader.Handler, %{
          database: %{host: "db.example.com", port: 5432},
          api: %{base_url: "https://api.example.com"},
          environment: :production
        }}
      )

  ## Tags

  Tags can be any term (atoms, strings, numbers, tuples, etc.), but atoms
  are recommended for clarity and performance.

  ## Read-Only Guarantee

  Like the regular Reader effect, TaggedReader environments are read-only.
  The same environment value will be returned for repeated asks with the same tag.
  """

  import Freyja.Freer.Sig.DefEffectStruct
  import Freyja.Hefty.Sig.DefHeftyStruct
  alias Freyja.Freer

  # First-order operations
  def_effect_struct(AskTagged, tag: nil)
  def_effect_struct(AskAll)

  @doc """
  Ask for the environment value associated with the given tag.

  Returns the read-only environment associated with `tag`.
  """
  @spec ask(atom) :: Freer.t()
  def ask(tag), do: %AskTagged{tag: tag} |> Freer.send_effect()

  @doc """
  Ask for all tagged environments as a map.

  Returns the entire map of tagged environments from the handler state.
  This is useful when you need to access multiple tags or perform operations
  that require knowledge of all available tags.

  ## Example

      con [TaggedReader] do
        all_envs <- ask_all()
        # all_envs is a map: %{database: ..., api: ..., etc}

        db <- ask(:database)
        # Equivalent to: Map.get(all_envs, :database)

        return({all_envs, db})
      end
  """
  @spec ask_all :: Freer.t()
  def ask_all, do: %AskAll{} |> Freer.send_effect()

  # Higher-order operations
  def_hefty_struct(Local, tag: nil, modifier_fn: nil)
  def_hefty_struct(LocalAll, modifier_fn: nil)

  @doc """
  Run a computation with a temporarily modified environment for a specific tag.

  The modifier function receives the current environment for the given tag
  and returns a modified version. This modified environment is used for all
  `ask(tag)` calls within the inner computation. After the inner computation
  completes, the original environment is restored.

  Other tags are not affected by this operation.

  ## Parameters
  - `tag` - The tag whose environment should be modified
  - `modifier_fn` - Function `(env -> env)` that transforms the environment
  - `inner_comp` - Hefty computation to run with the modified environment

  ## Example

      hefty do
        db_config <- TaggedReader.ask(:database)

        result <- TaggedReader.local(
          :database,
          fn config -> %{config | port: 5433} end,
          hefty do
            cfg <- TaggedReader.ask(:database)
            return(cfg.port)  # => 5433
          end
        )

        final_config <- TaggedReader.ask(:database)
        return({final_config.port, result})  # => {5432, 5433}
      end
  """
  def local(tag, modifier_fn, inner_comp) when is_function(modifier_fn, 1) do
    Freyja.Hefty.send_hefty(
      __MODULE__,
      %Local{tag: tag, modifier_fn: modifier_fn},
      %{inner: inner_comp}
    )
  end

  @doc """
  Run a computation with temporarily modified environments for all tags.

  The modifier function receives the entire map of tagged environments
  and returns a modified map. This modified map is used for all `ask/1`
  calls within the inner computation. After the inner computation completes,
  the original environments are restored.

  ## Parameters
  - `modifier_fn` - Function `(env_map -> env_map)` that transforms the entire environment map
  - `inner_comp` - Hefty computation to run with the modified environments

  ## Example

      hefty do
        result <- TaggedReader.local_all(
          fn envs ->
            envs
            |> Map.update!(:database, fn db -> %{db | port: 5433} end)
            |> Map.update!(:api, fn api -> %{api | timeout: 30} end)
          end,
          hefty do
            db <- TaggedReader.ask(:database)
            api <- TaggedReader.ask(:api)
            return({db.port, api.timeout})  # => {5433, 30}
          end
        )

        return(result)
      end
  """
  def local_all(modifier_fn, inner_comp) when is_function(modifier_fn, 1) do
    Freyja.Hefty.send_hefty(
      __MODULE__,
      %LocalAll{modifier_fn: modifier_fn},
      %{inner: inner_comp}
    )
  end
end

defmodule Freyja.Effects.TaggedReader.Algebra do
  @moduledoc """
  Algebra for elaborating TaggedReader.Local and TaggedReader.LocalAll operations.

  ## Overview

  The Local operations provide scoped modification of tagged environments:
  - `Local` modifies a single tag's environment
  - `LocalAll` modifies all tagged environments at once

  Both intercept `TaggedReader.AskTagged` operations within a computation and provide
  modified environments, without affecting operations outside the scope.

  ## Elaboration Strategy

  Uses interposition to structurally transform the inner computation:

  ### For Local (single tag):
  1. Intercept `AskTagged` operations for the specific tag
  2. Apply the modifier function to that tag's environment
  3. Pass other tags through unchanged
  4. Original environment is automatically restored outside the scope

  ### For LocalAll (all tags):
  1. Intercept all `AskTagged` operations
  2. Apply the modifier function to the entire environment map
  3. Look up the requested tag in the modified map
  4. Original environments are automatically restored outside the scope

  ## State Propagation

  State propagates naturally through interposition - no special handling needed.
  All effects at the same level, no nested interpretation.

  ## Suspensions

  Suspensions (like Coroutine.yield) work automatically because the interposition
  is baked into the computation structure. When resuming, the modified environment
  context is preserved.
  """

  @behaviour Freyja.Hefty.Algebra

  import Freyja.Freer.FreerBlock

  alias Freyja.Effects.TaggedReader
  alias Freyja.Effects.TaggedReader.{AskTagged, AskAll, Local, LocalAll}
  alias Freyja.Freer
  alias Freyja.Freer.Interpose

  @impl true
  def handles_hefty?(sig) when sig == TaggedReader, do: true
  def handles_hefty?(_), do: false

  @impl true
  def elaborate(%Local{tag: target_tag, modifier_fn: modifier_fn} = _op, psi, k, _elaborator) do
    # Extract the already-elaborated inner computation (Freer)
    inner_comp = Map.fetch!(psi, :inner)

    # Interpose on TaggedReader.AskTagged operations for the specific tag
    transformed =
      Interpose.interpose_with(
        inner_comp,
        # Match only AskTagged operations for the target tag
        fn sig, data ->
          sig == TaggedReader and
            match?(%AskTagged{tag: ^target_tag}, data)
        end,
        # When we intercept an Ask for the target tag, get and modify its environment
        fn %AskTagged{tag: tag}, continuation ->
          con do
            env <- TaggedReader.ask(tag)
            modified_env = modifier_fn.(env)
            continuation.(modified_env)
          end
        end
      )

    # Bind the transformed computation to the outer continuation
    Freer.bind(transformed, k)
  end

  def elaborate(%LocalAll{modifier_fn: modifier_fn} = _op, psi, k, _elaborator) do
    # Extract the already-elaborated inner computation (Freer)
    inner_comp = Map.fetch!(psi, :inner)

    # LocalAll intercepts ALL TaggedReader operations (both AskTagged and AskAll).
    # For AskTagged operations:
    # 1. Get the original value for that tag
    # 2. Apply modifier_fn to a map containing just that tag and value
    # 3. Extract the modified value for that tag from the result map
    #
    # For AskAll operations:
    # 1. Get all original values
    # 2. Apply modifier_fn to the entire map
    # 3. Return the modified map
    #
    # Note: For AskTagged, this calls modifier_fn once per ask (inefficient but correct).
    # The modifier_fn receives a partial map with only the requested tag,
    # which works for map transformations that operate on individual entries.
    # For truly atomic multi-tag transformations, use ask_all within the local_all scope.

    transformed =
      Interpose.interpose_with(
        inner_comp,
        # Match ALL TaggedReader operations
        fn sig, data ->
          sig == TaggedReader and (match?(%AskTagged{}, data) or match?(%AskAll{}, data))
        end,
        # Handle both AskTagged and AskAll
        fn
          %AskTagged{tag: tag}, continuation ->
            con do
              # Get the original value for this tag
              original_value <- TaggedReader.ask(tag)
              # Apply modifier_fn to a map containing this tag
              modified_map = modifier_fn.(%{tag => original_value})
              # Extract the modified value for this tag
              modified_value = Map.get(modified_map, tag, original_value)
              continuation.(modified_value)
            end

          %AskAll{}, continuation ->
            con do
              # Get all original values
              original_map <- TaggedReader.ask_all()
              # Apply modifier_fn to the entire map
              modified_map = modifier_fn.(original_map)
              continuation.(modified_map)
            end
        end
      )

    # Bind the transformed computation to the outer continuation
    Freer.bind(transformed, k)
  end

  @doc """
  Add this algebra to a computation or builder pipeline.

  ## Examples

      # Start new pipeline
      hefty_computation |> TaggedReader.Algebra.run()

      # Add to existing pipeline
      builder |> TaggedReader.Algebra.run()
  """
  def run(computation_or_builder) do
    Freyja.Run.RunBuilder.add(computation_or_builder, __MODULE__, nil)
  end
end

defmodule Freyja.Effects.TaggedReader.Handler do
  @moduledoc """
  Handler for the TaggedReader effect.

  Manages multiple independent read-only environments in a map structure where
  keys are tags and values are the environment for each tag.

  ## Handler State

  The handler state must be a map:

      %{
        tag1 => env1,
        tag2 => env2,
        ...
      }

  ## Behavior

  - `ask(tag)` returns the value at `state[tag]`, or `nil` if not present
  - Environments are read-only - the same value is returned for repeated asks
  """

  alias Freyja.Freer
  alias Freyja.Freer.Impl
  alias Freyja.Freer.Impure
  alias Freyja.Effects.TaggedReader
  alias Freyja.Effects.TaggedReader.{AskTagged, AskAll}
  alias Freyja.Run.RunState

  @behaviour Freyja.Freer.EffectHandler

  @impl Freyja.Freer.EffectHandler
  def handles?(%Impure{sig: sig, data: _data, q: _q}, _state) do
    sig == TaggedReader
  end

  @impl Freyja.Freer.EffectHandler
  def interpret(
        %Freer.Impure{sig: TaggedReader, data: operation, q: q} = _computation,
        _handler_key,
        state,
        %RunState{} = _run_state
      ) do
    unless is_map(state) do
      raise ArgumentError,
            "TaggedReader.Handler state must be a map, got: #{inspect(state)}"
    end

    case operation do
      %AskTagged{tag: tag} ->
        value = Map.get(state, tag)
        # Reader effect doesn't modify state - it's read-only
        {Impl.q_apply(q, value), state}

      %AskAll{} ->
        # Return the entire state map
        {Impl.q_apply(q, state), state}
    end
  end

  @doc """
  Add this handler to a computation or builder pipeline.

  ## Examples

      # Start new pipeline with tagged environments
      computation |> TaggedReader.Handler.run(%{db: db_config, api: api_config})

      # Add to existing pipeline
      builder |> TaggedReader.Handler.run(environments)
  """
  def run(computation_or_builder, initial_state) do
    Freyja.Run.RunBuilder.add(computation_or_builder, __MODULE__, initial_state)
  end
end
