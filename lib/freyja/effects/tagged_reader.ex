defmodule Freyja.Effects.TaggedReader do
  @moduledoc """
  Tagged Reader effect for accessing multiple independent read-only environments.

  Unlike the regular Reader effect which provides a single read-only environment,
  TaggedReader allows multiple independent environments identified by tags.

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

      Run.with_handlers(
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

  import Freyja.Sig.DefEffectStruct

  def_effect_struct(AskTagged, tag: nil)

  @doc """
  Ask for the environment value associated with the given tag.

  Returns the read-only environment associated with `tag`.
  """
  def ask(tag), do: %AskTagged{tag: tag}
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
  alias Freyja.Effects.TaggedReader.AskTagged
  alias Freyja.Run.RunState

  @behaviour Freyja.EffectHandler

  @impl Freyja.EffectHandler
  def handles?(%Impure{sig: sig, data: _data, q: _q}, _state) do
    sig == TaggedReader
  end

  @impl Freyja.EffectHandler
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
    end
  end
end
