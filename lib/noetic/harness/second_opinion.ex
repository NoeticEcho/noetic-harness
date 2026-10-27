defmodule Noetic.Harness.SecondOpinion do
  @moduledoc """
  A model may disagree with the router. It may not decide instead of it.

  The user settled this on 2026-09-22, and a design decision records it: in a harness
  decision a model is **advisory**. The deterministic mechanism stays the
  decision; the model is a second opinion, and it is surfaced only when it
  *disagrees*. An opinion that agrees is not information — the route already
  said so — and printing it would train a reader to skim the line that matters.

  ## The property this module exists for

  There is no provider. There may never be one on the machine this runs on, and
  An earlier change has not yet established that a model answers at all on a two-core
  Ivy Bridge Pentium with no AVX. So the seam is built and tested *first*,
  against nothing, because a path exercised only when something fails is a path
  nobody has tested.

  Four ways there is no opinion, and they are one outcome:

    * nothing is configured;
    * the configured module is not loaded — `noetic_harness` answers when the
      umbrella does not compile, so a provider living in another
      app is *expected* to be absent;
    * the call raised;
    * the call did not answer inside `deadline/0`.

  None of the four may change the route, and none may delay it past the budget.
  `on/1` returns `nil` for all of them and never raises.

  ## The budget

  `noetic-harness route` is a ~100 ms answer after an ~850 ms BEAM boot, measured
  in an earlier change. A second opinion that costs more than the route did is not
  a second opinion, it is the route — so the deadline is 250 ms, which is
  under a third of the routing it comments on and invisible beside the boot.

  Bounded in one layer, deliberately, and this is the difference from
  `Noetic.Harness.Beads`: `Task.yield/2` guarantees the *caller* returns, and
  that is all it guarantees. `Beads` needs `timeout(1)` as well because a `bd`
  that hangs holds a Dolt lock other sessions need. A provider that hangs holds
  nothing — it is in this VM, it is shut down brutally, and there is no
  external resource to reap. Saying "bounded" where only one layer applies is
  the §5 failure; saying it where one layer is the whole story is accurate.
  """

  alias Noetic.Harness.Router

  @deadline_ms 250

  @typedoc """
  What a provider is allowed to say. A workflow id and, optionally, why.

  Not a lane, not a trust level and not a team. A model that could name a lane
  could name `release`, and `.agents/constitution.md` §8 is that authority is
  scoped and not yours to raise — a design decision and the addendum's Gap 8 say the
  same thing in different words. What it may do is name a workflow, which the
  router then reports as a disagreement for a person to read.
  """
  @type verdict :: %{optional(:workflow) => String.t() | nil, optional(:why) => String.t() | nil}

  @doc "Answer, or do not. Raising is permitted; it is caught and read as `:error`."
  @callback consult(Router.route()) :: {:ok, verdict()} | :error

  @doc """
  Milliseconds a provider gets: 250, for the reason in the moduledoc.

  `config :noetic_harness, :second_opinion_deadline_ms` moves it, and a test is
  the reason it can. Whether an answer arrives inside 250 ms is a
  property of the machine as well as the code: the provider's reply crosses a
  `Task`, `:httpc` and a socket, and each of them waits for a scheduler. On
  2026-09-25 a ci-local run on the loaded two-core workstation had a fake
  server in `SecondOpinionSystemOneTest` answer at once and still be late: the
  disagreement was dropped as no opinion, correctly, and the test that it is
  *printed* failed. A test of what happens to an answer inside the deadline
  sets a deadline its machine cannot miss; the tests of the deadline itself
  keep this one.
  """
  @spec deadline() :: pos_integer()
  def deadline,
    do: Application.get_env(:noetic_harness, :second_opinion_deadline_ms, @deadline_ms)

  @doc """
  The configured provider, or `nil`.

  `nil` for every way of not having one: unset, set to something that is not a
  module, set to a module that is not loaded, or set to a module that does not
  implement the callback. Checked rather than assumed, because the common case
  on this machine is the third.
  """
  @spec provider() :: module() | nil
  def provider do
    case Application.get_env(:noetic_harness, :second_opinion) do
      module when is_atom(module) and not is_nil(module) ->
        if Code.ensure_loaded?(module) and function_exported?(module, :consult, 1),
          do: module,
          else: nil

      _not_a_module ->
        nil
    end
  end

  @doc """
  The line to print, or `nil`.

  `nil` means "say nothing", which is the answer for no provider, a provider
  that failed, a provider that took too long, a provider that answered
  nonsense, and a provider that agreed. Only a live disagreement produces text.
  """
  @spec on(Router.route()) :: String.t() | nil
  def on(route) do
    with module when is_atom(module) and not is_nil(module) <- provider(),
         {:ok, verdict} <- ask(module, route),
         {:ok, theirs} <- named(verdict),
         true <- theirs != ours(route) do
      line(theirs, verdict, route)
    else
      _no_opinion_or_no_disagreement -> nil
    end
  end

  defp ask(module, route) do
    deadline = deadline()
    task = Task.async(fn -> consult(module, route) end)

    case Task.yield(task, deadline) || Task.shutdown(task, :brutal_kill) do
      {:ok, {:ok, verdict}} when is_map(verdict) -> {:ok, verdict}
      _refused_or_late -> :error
    end
  end

  defp consult(module, route) do
    module.consult(route)
  rescue
    _ -> :error
  catch
    _, _ -> :error
  end

  # A provider that answers with no workflow, or with something that is not a
  # string, has not disagreed — it has failed to say anything. Read as no
  # opinion rather than as "route to nil", which is a real answer the router
  # itself can give and which a malformed reply must not be able to forge.
  defp named(%{workflow: id}) when is_binary(id) and id != "", do: {:ok, id}
  defp named(%{"workflow" => id}) when is_binary(id) and id != "", do: {:ok, id}
  defp named(_otherwise), do: :error

  defp ours(%{workflow: nil}), do: nil
  defp ours(%{workflow: workflow}), do: workflow["id"]

  defp line(theirs, verdict, route) do
    why =
      case verdict do
        %{why: text} when is_binary(text) and text != "" -> " — #{excerpt(text)}"
        %{"why" => text} when is_binary(text) and text != "" -> " — #{excerpt(text)}"
        _ -> ""
      end

    # One line, on purpose: this text goes to a terminal through
    # `noetic-harness route` and into an agent's context through `Attach`, and a
    # second line would have to be indented differently in each. A caller that
    # wants it indented indents it.
    "second opinion disagrees: #{theirs} where the router says " <>
      "#{ours(route) || "none"}#{why}. The router's answer stands; a model is " <>
      "advisory here."
  end

  # A provider's free text goes into a terminal and, through `Attach`, into an
  # agent's context. It is bounded and stripped of newlines so that it cannot
  # forge a second line of harness output — the same rule `noetic-harness hook`
  # applies to what it splices in.
  defp excerpt(text) do
    text
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> String.slice(0, 160)
  end
end
