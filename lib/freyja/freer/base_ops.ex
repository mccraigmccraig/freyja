defmodule Freyja.Freer.BaseOps do
  @moduledoc """
  Functions in this module will always be imported into
  Freer.con blocks
  """
  def return(x), do: Freyja.Freer.return(x)
end
