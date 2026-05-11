defmodule LongOrShort.Settings.Loader do
  @moduledoc """
  Boot-time hydration GenServer for `LongOrShort.Settings` -- LON-125.

  ## What "boot hydration" means

  The BEAM keeps application configuration in an in-memory key-value
  store accessed via `Application.get_env/2`. At app start, that
  store only contains the defaults compiled in from `config.exs` /
  `runtime.exs`. The `settings` DB table holds the admin-tunable
  overrides for those defaults. Without this loader, those rows
  would just be data in a table -- nothing reads them.

  This module bridges the two. At boot, before any worker that
  might consume a setting starts, we read every row from
  `settings`, cast its `:value` to the type indicated by `:type`,
  and call `Application.put_env(:long_or_short, key, cast_value)`.

  The result: the rest of the codebase never knows the DB exists.
  Every `Application.get_env(:long_or_short, :foo, default)` (or
  the `Settings.get!/2` wrapper) reads from in-memory env --
  zero-overhead, no DB hit, no provider abstraction.

  ## Why a supervised GenServer (vs a plain function call)

  Three reasons:

    1. **Boot ordering.** The Loader is a child in
       `LongOrShort.Application`'s supervision tree, placed *after*
       the Repo and *before* any worker that reads settings (Oban,
       feeders, etc.). The supervisor blocks until `init/1` returns,
       so downstream children see a fully-hydrated env.
    2. **Failure isolation.** A DB outage or a malformed row mustn't
       brick the whole app. Wrapping `init/1` work in a `try/rescue`
       lets us log + `{:ok, state}` so the supervisor moves on; the
       app boots with `config.exs` defaults.
    3. **Future extension.** Stage 5 of the LON-124 epic adds an
       audit log + change broadcasts. When a setting is updated via
       admin UI we want the Loader process to `Phoenix.PubSub`-listen
       and re-hydrate the affected key without an app restart. That's
       trivial to add to a process; harder if it's just a function
       called once.

  ## Boot flow

      Application.start/2
        -> Supervisor starts children in order:
             - Telemetry
             - Repo
             - Settings.Loader      <- here
                 init/1
                   1. Settings.list_settings!(actor: SystemActor)
                   2. for each row: cast value, Application.put_env
                   3. emit [:long_or_short, :settings, :hydrate] telemetry
                   4. return {:ok, %{}}
             - Oban
             - PubSub
             - ...

  ## Failure modes

    * **Repo unreachable / DB down** -- outer `try/rescue` catches,
      logs a `Logger.warning`, app still boots with `config.exs`
      defaults. The telemetry event still fires with `count: 0,
      errors: -1` so observability can flag "boot ran but no
      hydration."
    * **Single row malformed** (e.g. `:type` `:integer` but `:value`
      `"abc"`) -- per-row `with` chain returns `{:error, ...}`, the
      bad row is skipped, the rest hydrate normally. Logged at
      `Logger.warning` with the key + reason. The telemetry event
      reports the error count.
    * **Unknown atom key** -- `:key` `"foo_bar"` but no atom
      `:foo_bar` exists anywhere in compiled code. Treated as a
      malformed row (logged, skipped). This is also the security
      story: `String.to_existing_atom/1` rejects fabricated keys.

  ## What this Loader does NOT do

    * No auto-restart on setting change. Once a row is edited via
      admin UI, the value isn't reflected until the next boot. That
      is the Phase 1 contract (LON-124 spec). Live recompute lives
      in a future ticket.
    * No callback / event API. State is `%{}`. The process is idle
      after `init/1` -- it exists for supervision + future
      extension, not for messages today.
  """

  use GenServer

  require Logger

  alias LongOrShort.Accounts.SystemActor
  alias LongOrShort.Settings

  @doc """
  Start the Loader. Called by `LongOrShort.Application`. Named so
  introspection tools see one instance.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    hydrate()
    {:ok, %{}}
  end

  # ── Hydration ────────────────────────────────────────────────────

  defp hydrate do
    case safe_list() do
      {:ok, settings} ->
        {ok, errors} = apply_all(settings)
        Logger.info("Settings.Loader: hydrated #{ok} setting(s), #{errors} error(s)")

        :telemetry.execute(
          [:long_or_short, :settings, :hydrate],
          %{count: ok, errors: errors},
          %{}
        )

      {:error, reason} ->
        # DB self-failure (Repo down, query crash, etc.). The app must
        # still boot -- config.exs defaults are the fallback.
        Logger.warning(
          "Settings.Loader: hydration skipped (db error) -- #{inspect(reason)}. " <>
            "Keeping config.exs defaults."
        )

        :telemetry.execute(
          [:long_or_short, :settings, :hydrate],
          %{count: 0, errors: -1},
          %{}
        )
    end
  end

  defp safe_list do
    try do
      {:ok, Settings.list_settings!(actor: SystemActor.new())}
    rescue
      e -> {:error, e}
    end
  end

  defp apply_all(settings) do
    Enum.reduce(settings, {0, 0}, fn setting, {ok, err} ->
      case apply_setting(setting) do
        :ok ->
          {ok + 1, err}

        {:error, reason} ->
          Logger.warning(
            "Settings.Loader: skipping key=#{inspect(setting.key)} -- #{inspect(reason)}"
          )

          {ok, err + 1}
      end
    end)
  end

  defp apply_setting(setting) do
    with {:ok, atom_key} <- to_atom_key(setting.key),
         {:ok, cast_value} <- cast(setting.value, setting.type) do
      Application.put_env(:long_or_short, atom_key, cast_value)
      :ok
    end
  end

  # ── Atom key resolution ─────────────────────────────────────────

  # `String.to_existing_atom/1` rejects keys we don't already
  # reference somewhere -- prevents arbitrary atom creation and
  # accidental typos from polluting :long_or_short env.
  defp to_atom_key(key) when is_binary(key) do
    {:ok, String.to_existing_atom(key)}
  rescue
    ArgumentError -> {:error, {:unknown_atom, key}}
  end

  # ── Value casting ───────────────────────────────────────────────

  defp cast(value, :integer) when is_binary(value) do
    case Integer.parse(value) do
      {n, ""} -> {:ok, n}
      _ -> {:error, {:bad_integer, value}}
    end
  end

  defp cast(value, :decimal) when is_binary(value) do
    case Decimal.parse(value) do
      {d, ""} -> {:ok, d}
      _ -> {:error, {:bad_decimal, value}}
    end
  end

  defp cast("true", :boolean), do: {:ok, true}
  defp cast("false", :boolean), do: {:ok, false}
  defp cast(value, :boolean), do: {:error, {:bad_boolean, value}}

  defp cast(value, :atom) when is_binary(value) do
    {:ok, String.to_existing_atom(value)}
  rescue
    ArgumentError -> {:error, {:unknown_atom_value, value}}
  end

  defp cast(value, :string) when is_binary(value), do: {:ok, value}

  defp cast(value, type), do: {:error, {:unsupported, type, value}}
end
