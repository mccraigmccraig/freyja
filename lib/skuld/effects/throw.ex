defmodule Skuld.Effects.Throw do
  @moduledoc """
  Throw/Catch effects - error handling with scoped catching.

  Demonstrates control effects (non-resumption) and handler scoping.
  """

  alias Skuld
  alias Skuld.Env

  @effect_key :throw

  #############################################################################
  ## Operations
  #############################################################################

  @doc "Throw an error - does not resume"
  @spec throw(term()) :: Skuld.computation()
  def throw(error) do
    Skuld.effect(@effect_key, {:throw, error})
  end

  @doc """
  Catch errors from a sub-computation.

  If the sub-computation throws, the error handler is invoked.
  If it completes normally, the result is wrapped in {:ok, value}.
  """
  @spec catch_error(Skuld.computation(), (term() -> Skuld.computation())) :: Skuld.computation()
  def catch_error(comp, error_handler) do
    fn env, outer_resume ->
      # Install a catch handler that intercepts throws
      # Returns a special marker so we know to pass through without wrapping
      catch_handler = fn {:throw, error}, catch_env, _inner_resume ->
        # Return marker with recovery computation and env at catch point
        {:__caught__, error_handler.(error), catch_env}
      end

      modified_env = Env.with_handler(env, @effect_key, catch_handler)

      case comp.(modified_env, fn v, e -> {:done, v, e} end) do
        {:done, value, result_env} ->
          # Normal completion - restore original handler and resume with {:ok, value}
          restored_env = Env.with_handler(result_env, @effect_key, env.evidence[@effect_key])
          outer_resume.({:ok, value}, restored_env)

        {:__caught__, recovery_comp, catch_env} ->
          # Error was caught - run recovery and pass through WITHOUT wrapping
          restored_env = Env.with_handler(catch_env, @effect_key, env.evidence[@effect_key])
          recovery_comp.(restored_env, outer_resume)

        {:thrown, error, err_env} ->
          # Error propagated from deeper (uncaught at this level)
          {:thrown, error, err_env}

        {:suspended, yielded, inner_resume, susp_env} ->
          # Yield inside catch - wrap resume to maintain catch context
          wrapped_resume = fn input, resume_env ->
            # Re-install catch handler for resumed computation
            resumed_env = Env.with_handler(resume_env, @effect_key, catch_handler)

            case inner_resume.(input, resumed_env) do
              {:done, value, final_env} ->
                restored = Env.with_handler(final_env, @effect_key, env.evidence[@effect_key])
                outer_resume.({:ok, value}, restored)

              {:__caught__, recovery_comp, caught_env} ->
                restored = Env.with_handler(caught_env, @effect_key, env.evidence[@effect_key])
                recovery_comp.(restored, outer_resume)

              other ->
                other
            end
          end

          {:suspended, yielded, wrapped_resume, susp_env}
      end
    end
  end

  @doc "Catch and return Either-style result"
  @spec try_catch(Skuld.computation()) :: Skuld.computation()
  def try_catch(comp) do
    catch_error(comp, fn error -> Skuld.pure({:error, error}) end)
  end

  #############################################################################
  ## Handler Installation
  #############################################################################

  @doc """
  Install the default Throw handler.

  The default handler converts throw to a :thrown outcome.
  """
  @spec handler(Skuld.env()) :: Skuld.env()
  def handler(env) do
    Env.with_handler(env, @effect_key, &handle/3)
  end

  # Default handler - propagate as thrown outcome
  defp handle({:throw, error}, env, _resume) do
    {:thrown, error, env}
  end
end
