defmodule Freyja.Run.RunState do
  @moduledoc """
  state for running an effectful computation
  """
  defstruct handlers: [], states: %{}

  @type handler_key :: atom
  @type handler_mod :: atom
  @type handler_list :: list({handler_key, handler_mod})
  @type handler_states_map :: %{handler_key => any}

  @type handler_mod_with_state :: {atom, any}
  @type handler_spec :: handler_mod | handler_mod_with_state()
  @type handler_spec_list :: list({handler_key, handler_spec})

  @type t :: %__MODULE__{
          handlers: handler_list,
          states: handler_states_map
        }

  @doc """
  Build a new RunState with the provided EffectHandlers and their initial states.

  Takes a list of handler specs where each spec is either:
  - `{key, handler_module}` - Handler with nil state
  - `{key, {handler_module, initial_state}}` - Handler with explicit state
  """
  @spec new(handler_spec_list()) :: t()
  def new(handler_specs) do
    handler_specs
    |> Enum.map(fn
      {key, mod} when is_atom(key) and is_atom(mod) -> {key, {mod, nil}}
      {key, {mod, _state}} = spec_with_state when is_atom(key) and is_atom(mod) -> spec_with_state
    end)
    |> Enum.reduce(
      %__MODULE__{handlers: [], states: %{}},
      fn {key, {mod, state}}, acc ->
        if Map.has_key?(acc.states, key) do
          raise ArgumentError,
            message:
              "#{__MODULE__}.new handler_key already exists\n" <>
                "handler_key: #{inspect(key)}\n" <>
                "run_state: #{inspect(acc, pretty: true)}"
        end

        # make sure the EffectHandler behaviours are loaded!
        Code.ensure_loaded(mod)

        %{
          acc
          | handlers: [{key, mod} | acc.handlers],
            states: Map.put(acc.states, key, state)
        }
      end
    )
    |> then(fn %__MODULE__{handlers: handlers} = self ->
      %{self | handlers: Enum.reverse(handlers)}
    end)
  end
end
