defmodule LongOrShort.Settings.LoaderTest do
  @moduledoc """
  Tests for the boot-time hydration loader -- LON-125.

  Exercises `init/1` directly (no `start_link` / supervisor here)
  to verify hydration behaviour without spinning up another
  process. `async: false` because the loader writes into the
  global `:long_or_short` Application env, which is shared state.
  """

  use LongOrShort.DataCase, async: false

  alias LongOrShort.Accounts.SystemActor
  alias LongOrShort.Settings
  alias LongOrShort.Settings.Loader

  # Keys we exercise -- all atoms that already exist in compiled code
  # so `String.to_existing_atom/1` accepts them.
  @keys [
    :dilution_profile_window_days,
    :insider_post_filing_window_days
  ]

  setup do
    # Snapshot current env for our keys, restore at exit so other
    # tests are unaffected. config.exs sets defaults for these
    # (180 / 30) -- we don't want to leak overrides.
    saved = for k <- @keys, do: {k, Application.get_env(:long_or_short, k)}

    on_exit(fn ->
      for {k, v} <- saved do
        case v do
          nil -> Application.delete_env(:long_or_short, k)
          val -> Application.put_env(:long_or_short, k, val)
        end
      end
    end)

    :ok
  end

  defp seed!(attrs) do
    Settings.create_setting!(attrs, actor: SystemActor.new())
  end

  describe "init/1 -- empty DB" do
    test "returns {:ok, %{}} when there are no settings rows" do
      assert {:ok, %{}} = Loader.init([])
    end
  end

  describe "init/1 -- happy path" do
    test "hydrates an integer setting into Application env" do
      seed!(%{key: "dilution_profile_window_days", value: "360", type: :integer})

      assert {:ok, %{}} = Loader.init([])
      assert Application.get_env(:long_or_short, :dilution_profile_window_days) == 360
    end

    test "hydrates multiple rows independently" do
      seed!(%{key: "dilution_profile_window_days", value: "120", type: :integer})
      seed!(%{key: "insider_post_filing_window_days", value: "45", type: :integer})

      assert {:ok, %{}} = Loader.init([])
      assert Application.get_env(:long_or_short, :dilution_profile_window_days) == 120
      assert Application.get_env(:long_or_short, :insider_post_filing_window_days) == 45
    end

    test "decimal type produces a Decimal struct" do
      # `:qwen_region` happens to be an atom-typed setting, but here
      # we just need an atom key already known to the BEAM for the
      # decimal test. Reuse one that's defined and atom-cast safe.
      seed!(%{
        key: "dilution_profile_window_days",
        value: "180.5",
        type: :decimal
      })

      assert {:ok, %{}} = Loader.init([])
      val = Application.get_env(:long_or_short, :dilution_profile_window_days)
      assert %Decimal{} = val
      assert Decimal.equal?(val, Decimal.new("180.5"))
    end

    test "boolean true/false strings cast to bools" do
      seed!(%{
        key: "dilution_profile_window_days",
        value: "true",
        type: :boolean
      })

      assert {:ok, %{}} = Loader.init([])
      assert Application.get_env(:long_or_short, :dilution_profile_window_days) == true
    end
  end

  describe "init/1 -- malformed rows" do
    test "bad integer value -- row skipped, init still returns {:ok, %{}}" do
      seed!(%{
        key: "dilution_profile_window_days",
        value: "abc",
        type: :integer
      })

      Application.delete_env(:long_or_short, :dilution_profile_window_days)

      assert {:ok, %{}} = Loader.init([])

      # Bad row didn't write the bogus value; env stays at default
      # (nil after the explicit delete above).
      assert Application.get_env(:long_or_short, :dilution_profile_window_days) == nil
    end

    test "one bad row does not prevent siblings from hydrating" do
      seed!(%{key: "dilution_profile_window_days", value: "bad", type: :integer})
      seed!(%{key: "insider_post_filing_window_days", value: "30", type: :integer})

      Application.delete_env(:long_or_short, :dilution_profile_window_days)
      Application.delete_env(:long_or_short, :insider_post_filing_window_days)

      assert {:ok, %{}} = Loader.init([])

      # Good row hydrated, bad row stays unset.
      assert Application.get_env(:long_or_short, :dilution_profile_window_days) == nil
      assert Application.get_env(:long_or_short, :insider_post_filing_window_days) == 30
    end

    test "unknown atom key is rejected (security: no atom fabrication)" do
      # `:never_referenced_atom_xxxxxx` doesn't exist anywhere in
      # code, so `String.to_existing_atom/1` raises -- the loader
      # catches that and skips the row.
      seed!(%{
        key: "never_referenced_atom_xxxxxx",
        value: "1",
        type: :integer
      })

      assert {:ok, %{}} = Loader.init([])
    end
  end

  describe "init/1 -- telemetry" do
    test "emits :hydrate event with count and errors" do
      seed!(%{key: "dilution_profile_window_days", value: "200", type: :integer})

      :telemetry.attach(
        "loader-test-handler",
        [:long_or_short, :settings, :hydrate],
        fn _name, measurements, _meta, pid -> send(pid, {:hydrate, measurements}) end,
        self()
      )

      on_exit(fn -> :telemetry.detach("loader-test-handler") end)

      Loader.init([])

      assert_receive {:hydrate, %{count: 1, errors: 0}}
    end

    test "errors are counted (telemetry reports them)" do
      seed!(%{key: "dilution_profile_window_days", value: "bad", type: :integer})
      seed!(%{key: "insider_post_filing_window_days", value: "30", type: :integer})

      :telemetry.attach(
        "loader-test-errors",
        [:long_or_short, :settings, :hydrate],
        fn _name, measurements, _meta, pid -> send(pid, {:hydrate, measurements}) end,
        self()
      )

      on_exit(fn -> :telemetry.detach("loader-test-errors") end)

      Loader.init([])

      assert_receive {:hydrate, %{count: 1, errors: 1}}
    end
  end
end
