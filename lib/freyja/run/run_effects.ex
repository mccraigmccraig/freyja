defmodule Freyja.Run.RunEffects do
  @moduledoc """
  Placeholder module for potential future privileged runtime effects.

  Previously contained ScopedOk for runner-effect pattern state propagation,
  but this has been removed after converting all higher-order effects to use
  interposition-based elaboration (which doesn't need nested Run.run() calls
  or special state propagation mechanisms).

  This module is kept as a namespace placeholder in case future runtime-level
  effects are needed.
  """
end
