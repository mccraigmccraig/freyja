defprotocol Skuld.Comp.ISentinel do
  @moduledoc "Protocol for handling sentinel values in run/run!"
  @fallback_to_any true

  @doc "Complete a computation result - invoke leave_scope or bypass for sentinels"
  @spec run(t, Skuld.Comp.env()) :: {Skuld.Comp.result(), Skuld.Comp.env()}
  def run(result, env)

  @doc "Extract value or raise for sentinel types"
  @spec run!(t) :: term()
  def run!(value)
end

defimpl Skuld.Comp.ISentinel, for: Any do
  def run(result, env), do: env.leave_scope.(result, env)
  def run!(value), do: value
end
