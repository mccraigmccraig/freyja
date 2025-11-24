defprotocol Freyja.Freer.Sig.ISignature do
  @fallback_to_any false

  @spec signature(term) :: atom
  def signature(eff)
end
