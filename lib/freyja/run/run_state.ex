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
end
