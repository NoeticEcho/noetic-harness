defmodule Noetic.Harness.Adapter do
  @moduledoc """
  What a dispatched step is actually sent to.

  `Dispatcher` decides *whether* a step may run and composes what it is told;
  an adapter is the thing that runs it. Keeping them apart is what lets the
  model change without touching the module the evaluator fence protects.

  ## The five, and the order they are worth reaching for

  | id | what it is | what it needs |
  |---|---|---|
  | `null` | runs nothing, returns the prompt | nothing |
  | `claude_code` | `claude -p` | the `claude` binary, already signed in |
  | `api` | the Anthropic API | `ANTHROPIC_API_KEY` |
  | `router` | several providers behind one endpoint | `NOETIC_MODEL_ROUTER_URL`, `NOETIC_MODEL_ROUTER_KEY` |
  | `jido` | a Jido agent whose actions run in a sandboxed peer BEAM, planned by a local model | the adapter's application loaded, bubblewrap, and the planner's model served by Ollama on loopback — no key |

  **`null` is the default and stays the default.** A default that dispatches
  for real is one misconfiguration away from spending money in CI.

  **`claude_code` is the one to prefer** where it works. It rides the Claude
  Code subscription the person is already signed in to, so there is no key —
  and a credential that does not exist cannot leak into a log, a bead or a
  prompt.

  ## Chosen by id, never by module name

  `.agents/policies/models.json` names an adapter by *id*, and the id-to-module
  table is in this file. A policy file that could name a module would be a
  policy file that can run arbitrary code, and the whole point of putting the
  policy in `.agents/policies/` is that the fence stops a dispatched run
  editing it — an agent that can pick its own model can give itself a better
  one at the user's expense.

  ## An adapter that cannot run is unavailable, not a reason to use another one

  §33. `available?/1` asks whether the credentials and binaries an adapter
  declares are actually there, and `resolve/1` returns `{:unavailable, why}`
  rather than quietly falling back. Silently choosing a different provider
  because the configured one had no key is exactly the class of thing that
  turns "which model produced this measurement?" into a guess — and
  An earlier change's promotion gate has to answer that question.

  ## Trust picks the model, and only downward

  `by_trust` in the policy maps the *derived* trust to a model and to whether
  the agent gets command execution at all. T0 reads and maps, so it runs on the
  cheapest model that can read, with `--restricted`. T3 is the most
  consequential thing a dispatched run may do and gets the most capable. There
  is no entry for T4 or T5 because those are not dispatched at all — see
  `Noetic.Harness.Dispatcher`.

  The model does not carry trust with it. A router that can reach a more
  capable model does not thereby grant one; `Policy.derive_trust/3` remains the
  only place trust is decided, and it only narrows.
  """

  alias Noetic.Harness.Loader

  @doc """
  Run a composed prompt.

  `opts` carries at least `:cwd` (the run's worktree — an adapter must not work
  anywhere else), `:trust` and `:model`. The result is a map; `:output` is what
  the agent said, and `:cost_usd` and `:usage` are what it cost, where the
  adapter can tell.
  """
  @callback call(prompt :: String.t(), opts :: keyword()) :: {:ok, map()} | {:error, term()}

  @doc """
  Whether this adapter could run at all, right now, on this machine.

  `:ok`, or `{:unavailable, why}` naming what is missing. Never a boolean: a
  caller handed `false` has to invent the sentence, and the sentence is the
  useful part.
  """
  @callback available?() :: :ok | {:unavailable, String.t()}

  @doc """
  The model this adapter will actually run, given the one `by_trust` named.

  Optional; without it the named model is the answer. `jido` implements it
  because its planner is one local model at every trust, whatever `by_trust`
  says — and "was this step reviewed by a different model?" has to be asked
  about the model that ran, before it runs (`Dispatcher`'s
  `independent_model?`). Comparing a reported model with a requested alias
  would call jido reviewing jido independent.
  """
  @callback runs_model(requested :: String.t() | nil) :: String.t() | nil

  @optional_callbacks runs_model: 1

  @doc "The model `mod` will run for `requested`, asking the adapter when it knows better."
  @spec effective_model(module(), String.t() | nil) :: String.t() | nil
  def effective_model(mod, requested) do
    if Code.ensure_loaded?(mod) and function_exported?(mod, :runs_model, 1),
      do: mod.runs_model(requested),
      else: requested
  end

  @doc """
  The models a review step may be given, in order of preference.

  A step declared `independent_of` another is dispatched to the first of these
  that the step under review did not use — see `Dispatcher`. The list is
  policy (`models.json` → `review.models`), inside the evaluator fence,
  because a reviewer that can choose its own model can choose a lenient one.
  `[]` when the policy has none, which makes every review of a dispatched step
  a refusal rather than a silent same-model review.
  """
  @spec review_models() :: [String.t()]
  def review_models do
    case policy() do
      {:ok, %{"review" => %{"models" => models}}} when is_list(models) ->
        Enum.filter(models, &is_binary/1)

      _ ->
        []
    end
  end

  @families ~w(opus sonnet haiku fable)

  @doc """
  The model family a model name belongs to, for the one question it answers:
  *is this the same model?*

  Deliberately coarse. `sonnet`, `claude-sonnet-5` and a router's
  `anthropic/claude-sonnet-5` are one model to a reviewer's independence, and
  so are Opus 5 and Opus 5.5 — treating two versions of a family as the same
  model can only cost a reviewer, never pass a review that was not
  independent. A name in no known family is its own family, compared whole.
  """
  @spec model_family(String.t() | nil) :: String.t() | nil
  def model_family(nil), do: nil

  def model_family(model) when is_binary(model) do
    name = String.downcase(model)
    Enum.find(@families, &String.contains?(name, &1)) || name
  end

  @modules %{
    "null" => Noetic.Harness.Dispatcher.NullAdapter,
    "claude_code" => Noetic.Harness.Adapter.ClaudeCode,
    "api" => Noetic.Harness.Adapter.Api,
    "router" => Noetic.Harness.Adapter.Router,
    "jido" => MyApp.Agents.HarnessAdapter
  }

  # Adapters whose module is not in this app, and the app it is in. The harness
  # never compiles against them — `noetic_harness` must answer on a machine
  # where the application does not build — so the table names the
  # module as an atom, which is code naming code, and `available?/1` says where
  # it lives when it is not loaded rather than failing to call it.
  @elsewhere %{"jido" => "my_app_agents"}

  @doc "Adapter ids whose module lives outside the harness, and where."
  @spec elsewhere() :: %{String.t() => String.t()}
  def elsewhere, do: @elsewhere

  @doc "Every adapter id this code knows how to run."
  @spec ids() :: [String.t()]
  def ids, do: @modules |> Map.keys() |> Enum.sort()

  @doc "The module for an id, or `:error` — never a module named by data."
  @spec module(String.t()) :: {:ok, module()} | :error
  def module(id), do: Map.fetch(@modules, id)

  @doc "The policy as loaded."
  @spec policy() :: {:ok, map()} | {:error, String.t()}
  def policy do
    Loader.cached_load(Path.join(Noetic.Harness.agents_path("policies"), "models.json"))
  end

  @doc """
  The adapter id in force.

  Application configuration wins over the policy's `default`, because a test
  and a one-off need to point this somewhere without editing a fenced file.
  Configuration cannot name a module, only an id, for the reason in the
  moduledoc.
  """
  @spec configured() :: String.t()
  def configured do
    case Application.get_env(:noetic_harness, :dispatch_adapter_id) do
      nil ->
        case policy() do
          {:ok, doc} -> doc["default"] || "null"
          {:error, _} -> "null"
        end

      id ->
        id
    end
  end

  @doc """
  Which adapter and which model this dispatch gets.

  Returns `{:ok, plan}` with `:id`, `:module`, `:model` and `:restricted`, or
  `{:unavailable, why}` when the chosen adapter's credentials or binary are not
  here. It does **not** pick a different one: see §33 in the moduledoc.
  """
  @spec resolve(String.t() | nil) :: {:ok, map()} | {:unavailable, String.t()}
  def resolve(trust) do
    id = configured()

    with {:ok, mod} <- fetch_module(id),
         :ok <- integration(id),
         {:ok, doc} <- fetch_policy(),
         :ok <- available?(mod) do
      settings = find(doc["by_trust"], "trust", trust) || %{}

      {:ok,
       %{
         id: id,
         module: mod,
         model: effective_model(mod, settings["model"]),
         restricted: Map.get(settings, "restricted", true)
       }}
    end
  end

  @doc """
  Ask an adapter whether it could run, and say why not in its own words.
  """
  @spec available?(module()) :: :ok | {:unavailable, String.t()}
  def available?(mod), do: available?(mod, Code.ensure_loaded?(mod))

  # Whether the module is loadable depends on how the suite was started: run
  # alone, `noetic_harness` cannot see the adapter's application; run from the umbrella
  # root, as `scripts/ci-local.sh` does, it can. The test of the "lives
  # elsewhere" answer asserted the first and failed under the second, so the
  # fact is a parameter the test can hold still.
  @doc false
  def available?(mod, loaded?) do
    if loaded? do
      mod.available?()
    else
      app = Enum.find_value(@modules, fn {id, m} -> m == mod && Map.get(@elsewhere, id) end)

      {:unavailable,
       "#{inspect(mod)} is not loaded here" <>
         if(app,
           do:
             " — it lives in #{app}, which the harness does not load; dispatch from a node " <>
               "that has #{app} in its code path",
           else: ""
         )}
    end
  rescue
    error -> {:unavailable, "#{inspect(mod)} could not be asked: #{Exception.message(error)}"}
  end

  @doc """
  Whether every environment variable an adapter declares in the policy is set.

  Only that it is set. The value is never read here, never logged, never
  returned — this answers "is there a credential?" and nothing about what it
  is.
  """
  @spec credentials(String.t()) :: :ok | {:unavailable, String.t()}
  def credentials(id) do
    with {:ok, doc} <- fetch_policy() do
      needs = (find(doc["adapters"], "id", id) || %{})["needs"] || []

      case Enum.reject(needs, &(System.get_env(&1) not in [nil, ""])) do
        [] ->
          :ok

        missing ->
          {it, them} = if length(missing) == 1, do: {"it is", "it"}, else: {"they are", "them"}

          {:unavailable,
           "#{id} needs #{Enum.join(missing, " and ")} in the environment, and " <>
             "#{it} not set. Set #{them} where the session can see #{them}; do not " <>
             "put #{them} in a file this repository tracks"}
      end
    end
  end

  # The policy's two lists are arrays rather than maps, so that the validator's
  # schema subset actually checks the keys inside them — it enforces `required`
  # under `items` and does not enforce `additionalProperties` used as a schema.
  # A map would have had a schema nobody was checking it against, which is the
  # defect this same change fixed for `evaluators.json`.
  defp find(nil, _key, _value), do: nil
  defp find(_list, _key, nil), do: nil

  defp find(list, key, value) when is_list(list),
    do: Enum.find(list, &(is_map(&1) and &1[key] == value))

  defp find(_list, _key, _value), do: nil

  # The `jido` adapter is an integration: its module lives in
  # another application, and a repository without it says so here, where
  # the adapter would otherwise be asked whether it is loaded.
  defp integration("jido") do
    if Noetic.Harness.Integrations.enabled?("jido"),
      do: :ok,
      else: {:unavailable, Noetic.Harness.Integrations.off("jido")}
  end

  defp integration(_id), do: :ok

  defp fetch_module(id) do
    case module(id) do
      {:ok, mod} ->
        {:ok, mod}

      :error ->
        {:unavailable,
         "no adapter is called #{inspect(id)}. The ones this code can run are " <>
           "#{Enum.join(ids(), ", ")} — `.agents/policies/models.json` names one of those"}
    end
  end

  defp fetch_policy do
    case policy() do
      {:ok, doc} -> {:ok, doc}
      {:error, message} -> {:unavailable, "the model policy could not be read: #{message}"}
    end
  end
end
