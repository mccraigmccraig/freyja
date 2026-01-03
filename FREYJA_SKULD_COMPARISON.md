# Freyja vs Skuld Core API Comparison

This document compares the two algebraic effects implementations in this repository:
- **Freyja**: Centralised interpreter with Freer/Hefty type bifurcation
- **Skuld**: Decentralised evidence-passing with unified computation type

## Architecture

| Aspect | Freyja | Skuld |
|--------|--------|-------|
| **Interpretation** | Centralised interpreter | Decentralised evidence-passing |
| **Effect types** | Two types: Freer (first-order) + Hefty (higher-order) | One type: `computation` |
| **Handler storage** | Accumulated in RunBuilder, applied during run | Stored in `env.evidence`, invoked directly |
| **Scope cleanup** | Manual via handler state | Built-in `leave_scope` chain |

## Type Complexity

### Freyja - Two distinct computation types

```elixir
# First-order (simple operations)
Freer.Pure{val: any}
Freer.Impure{sig: atom, data: any, q: [continuation]}

# Higher-order (operations taking computations)
Hefty.Pure{val: any}  
Hefty.Impure{sig: atom, data: struct, psi: map, k: fn}
```

### Skuld - Single unified type

```elixir
# All computations are just functions
computation :: (env, k -> {result, env})
```

**Winner: Skuld** - No bifurcation, no need to understand when to use Freer vs Hefty.

## Defining Effects

### Freyja - Different macros for first-order vs higher-order

```elixir
# First-order effect
def_effect_struct(Get)
def get, do: %Get{} |> Freer.send_effect()

# Higher-order effect (completely different pattern!)
def_hefty_struct(Catch, type: :any, handler: nil)
def catch_hefty(try_comp, handler) do
  Hefty.send_hefty(__MODULE__, %Catch{...}, %{try: try_comp})
end
```

### Skuld - Uniform pattern

```elixir
# First-order effect
def_op(Get)
def get, do: Comp.effect(@sig, %Get{})

# Higher-order is just... passing computations!
def local(modify, comp) do
  Comp.scoped(comp, fn env -> ... end)
end
```

**Winner: Skuld** - Higher-order effects are just functions that take computations.

## Handler Installation

### Freyja - Handlers accumulated, applied at run time

```elixir
con do ... end
|> State.Handler.run(0)      # Add to builder
|> Writer.Handler.run([])    # Add to builder
|> Run.run()                 # NOW handlers are installed

# Nested/scoped handlers require explicit Hefty elaboration:
hefty do
  result <- Catch.catch_hefty(inner_comp, handler)
  ...
end
|> Catch.Algebra.run()       # Algebra for elaboration
|> Lift.Algebra.run()        # Need this too!
|> State.Handler.run(0)
|> Run.run()
```

### Skuld - Handlers installed immediately, scoped automatically

```elixir
comp do ... end
|> State.with_handler(0)     # Installed NOW, scoped
|> Reader.with_handler(cfg)  # Installed NOW, scoped
|> Comp.run()

# Nested handlers - just nest the pipes!
comp do
  outer_state <- State.get()
  inner_result <- (
    comp do
      inner_state <- State.get()  # Different State!
      return(inner_state)
    end
    |> State.with_handler(999)    # Inner, independent State
  )
  return({outer_state, inner_result})
end
|> State.with_handler(0)
|> Comp.run()
```

**Winner: Skuld** - Scoped handlers are first-class, no Hefty/Algebra ceremony.

## Syntax Macros

### Freyja - Two syntaxes

```elixir
# First-order effects
con [State, Writer] do    # Must declare effect modules
  x <- State.get()
  return(x)
end

# Higher-order effects
hefty do                  # Different macro!
  x <- State.get()        # Auto-lifted from Freer
  result <- Catch.catch_hefty(...)
  return(result)
else
  pattern -> ...
catch
  error -> ...
end
```

### Skuld - One syntax

```elixir
comp do                   # Just one macro
  x <- State.get()
  result <- some_comp     # Any computation works
  return(result)
else
  pattern -> ...
catch
  error -> ...
end

# Function definitions
defcomp my_func(arg) do
  x <- State.get()
  return(x + arg)
end
```

**Winner: Skuld** - Single `comp` macro covers all cases.

## Running Computations

### Freyja

```elixir
outcome = computation
|> Handler1.run(state)
|> Handler2.run(state)
|> Run.run()              # Returns RunOutcome struct

# Extract result
outcome.result
outcome.outputs[Handler1]

# Or use helpers
Run.eval(builder)  # Just result
Run.exec(builder)  # Just outputs
```

### Skuld

```elixir
{result, final_env} = computation
|> Handler1.with_handler(state)
|> Handler2.with_handler(state)
|> Comp.run()

# Or extract directly
result = Comp.run!(computation)
```

**Winner: Skuld** - Simpler return type, no RunOutcome ceremony.

## Higher-Order Effects Comparison

### Freyja's `Catch.catch_hefty`

```elixir
hefty do
  result <- Catch.catch_hefty(
    hefty do
      x <- risky_op()
      return(x)
    end,
    fn err -> return(:recovered) end
  )
  return(result)
end
|> Catch.Algebra.run()     # Need algebra
|> Lift.Algebra.run()      # Need lift algebra
|> Throw.Handler.run()
|> Run.run()
```

### Skuld's `Throw.catch_error`

```elixir
comp do
  result <- Throw.catch_error(
    comp do
      x <- risky_op()
      return(x)
    end,
    fn err -> return(:recovered) end
  )
  return(result)
end
|> Throw.with_handler()
|> Comp.run()
```

Or even simpler with the `catch` clause:

```elixir
comp do
  x <- risky_op()
  return(x)
catch
  err -> return(:recovered)
end
|> Throw.with_handler()
|> Comp.run()
```

**Winner: Skuld** - No algebra layer, catch clause built into syntax.

## Feature Summary

| Feature | Freyja | Skuld |
|---------|--------|-------|
| Computation types | 2 (Freer + Hefty) | 1 |
| Syntax macros | 2 (`con` + `hefty`) | 1 (`comp`) |
| Higher-order effects | Require Hefty + Algebras | Just functions |
| Scoped handlers | Manual via Hefty | Built-in |
| Handler installation | At run time | Immediate, scoped |
| Effect module declaration | Required in `con` | Not needed |
| Leave-scope cleanup | Manual | Automatic |

## Why Skuld is Cleaner

1. **No Freer/Hefty bifurcation** - One computation type handles everything. Users don't need to understand when to use first-order vs higher-order effect abstractions.

2. **Scoped handlers are first-class** - `with_handler` installs handlers immediately with automatic cleanup on scope exit (both normal and abnormal).

3. **Higher-order effects are just functions** - No algebra elaboration step. A higher-order effect like `local` or `catch_error` is simply a function that takes a computation and returns a computation.

4. **Single syntax macro** - The `comp` macro works for all cases. No need to choose between `con` and `hefty` based on what effects you're using.

5. **Simpler mental model** - Computations are `(env, k) -> {result, env}`, handlers live in `env.evidence`, and the `leave_scope` chain handles cleanup automatically.

## Trade-offs

Freyja's approach does have some advantages:

- **Explicit elaboration** - The Hefty->Freer elaboration makes the transformation of higher-order effects explicit and inspectable
- **Handler outputs** - The `RunOutcome.outputs` map provides a clean way to extract final handler states
- **Effect declaration** - The `con [State, Writer] do` syntax makes dependencies explicit (though this is arguably boilerplate)

However, for most use cases, Skuld's simpler model is easier to understand, use, and debug.
