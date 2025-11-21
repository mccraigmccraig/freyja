[
  # Ignore all warnings in examples - these use effect DSL patterns that dialyzer
  # doesn't fully understand (auto-lifting of bare structs, effect computations, etc.)
  ~r"lib/freyja/examples/"
]
