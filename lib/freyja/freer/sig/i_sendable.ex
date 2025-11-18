defprotocol Freyja.Freer.Sig.ISendable do
  @fallback_to_any true

  @spec send(t) :: Freyja.Freer.freer()
  def send(eff)
end
