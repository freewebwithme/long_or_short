defmodule LongOrShortWeb.ProfileLive do
  @moduledoc """
  /profile — three-section editor: personal info, password change, trader profile.

  Each section is an independent AshPhoenix form. Saving one section does not
  reset the drafts of the others.

  ## Personal info

  `UserProfile` (LON-97) is lazily created on first /profile visit so the edit
  form always has a record to bind to. Email is shown disabled — changing it
  requires re-confirmation, which is a separate flow not in scope for LON-98.

  ## Change password

  Calls the existing `User.change_password` action. On success, the
  `log_out_everywhere` add-on (configured on the User resource) signs the user
  out of all *other* sessions. The current session is preserved to avoid a
  jarring redirect.

  ## Trader profile

  `TradingProfile` (LON-88) drives prompt personalization. Required fields
  (`trading_style`, `time_horizon`) are surfaced as `Select one...`
  prompts so the trader makes a deliberate choice — no default is
  auto-injected (LON-102). The form is rendered whether a profile
  exists yet or not; the first valid submit creates the row via
  `:upsert`, subsequent submits use `:update`. Style-specific fields
  (price band, float cap) render conditionally based on the current
  `:trading_style` selection, matching how the prompt builder
  consumes them.
  """

  use LongOrShortWeb, :live_view

  alias LongOrShort.Accounts

  @trading_styles [
    {"Momentum (small-cap day)", :momentum_day},
    {"Large-cap day", :large_cap_day},
    {"Swing", :swing},
    {"Position", :position},
    {"Options", :options}
  ]

  @time_horizons [
    {"Intraday", :intraday},
    {"Multi-day", :multi_day},
    {"Multi-week", :multi_week},
    {"Multi-month", :multi_month}
  ]

  @market_caps [
    {"Micro (<$300M)", :micro},
    {"Small ($300M–$2B)", :small},
    {"Mid ($2B–$10B)", :mid},
    {"Large ($10B+)", :large}
  ]

  @catalysts [
    {"Partnership", :partnership},
    {"M&A", :ma},
    {"FDA", :fda},
    {"Earnings", :earnings},
    {"Offering", :offering},
    {"RFP", :rfp},
    {"Contract win", :contract_win},
    {"Guidance", :guidance},
    {"Clinical", :clinical},
    {"Regulatory", :regulatory},
    {"Analyst", :analyst},
    {"Macro", :macro},
    {"Sector", :sector},
    {"Other", :other}
  ]

  # ── Mount ───────────────────────────────────────────────────────────

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_user
    user_profile = ensure_user_profile(user)
    trading_profile = load_trading_profile(user)

    {:ok,
     socket
     |> assign(:user_profile, user_profile)
     |> assign(:trading_profile, trading_profile)
     |> assign_personal_info_form()
     |> assign_password_form()
     |> assign_trading_profile_form()}
  end

  defp ensure_user_profile(user) do
    case Accounts.get_user_profile_by_user(user.id, actor: user) do
      {:ok, nil} ->
        {:ok, profile} = Accounts.upsert_user_profile(%{user_id: user.id}, actor: user)
        profile

      {:ok, profile} ->
        profile
    end
  end

  defp load_trading_profile(user) do
    case Accounts.get_trading_profile_by_user(user.id, actor: user) do
      {:ok, profile} -> profile
      _ -> nil
    end
  end

  defp assign_personal_info_form(socket) do
    user = socket.assigns.current_user
    form = AshPhoenix.Form.for_update(socket.assigns.user_profile, :update, actor: user)
    assign(socket, :personal_info_form, to_form(form))
  end

  defp assign_password_form(socket) do
    user = socket.assigns.current_user
    form = AshPhoenix.Form.for_update(user, :change_password, actor: user)
    assign(socket, :password_form, to_form(form))
  end

  defp assign_trading_profile_form(socket) do
    user = socket.assigns.current_user

    form =
      case socket.assigns.trading_profile do
        nil ->
          # First-time visitor: empty :upsert form. user_id is pre-filled
          # from the session so the form can't be retargeted to another user.
          AshPhoenix.Form.for_create(
            LongOrShort.Accounts.TradingProfile,
            :upsert,
            params: %{"user_id" => user.id},
            actor: user
          )

        profile ->
          AshPhoenix.Form.for_update(profile, :update, actor: user)
      end

    assign(socket, :trading_profile_form, to_form(form))
  end

  # ── Personal info handlers ──────────────────────────────────────────

  @impl true
  def handle_event("validate_personal_info", %{"form" => params}, socket) do
    form = AshPhoenix.Form.validate(socket.assigns.personal_info_form.source, params)
    {:noreply, assign(socket, :personal_info_form, to_form(form))}
  end

  def handle_event("save_personal_info", %{"form" => params}, socket) do
    case AshPhoenix.Form.submit(socket.assigns.personal_info_form.source, params: params) do
      {:ok, profile} ->
        {:noreply,
         socket
         |> put_flash(:info, "Personal info updated.")
         |> assign(:user_profile, profile)
         |> assign_personal_info_form()}

      {:error, form} ->
        {:noreply, assign(socket, :personal_info_form, to_form(form))}
    end
  end

  # ── Password handlers ───────────────────────────────────────────────

  def handle_event("validate_password", %{"form" => params}, socket) do
    form = AshPhoenix.Form.validate(socket.assigns.password_form.source, params)
    {:noreply, assign(socket, :password_form, to_form(form))}
  end

  def handle_event("save_password", %{"form" => params}, socket) do
    case AshPhoenix.Form.submit(socket.assigns.password_form.source, params: params) do
      {:ok, _user} ->
        {:noreply,
         socket
         |> put_flash(
           :info,
           "Password updated. Other browser sessions have been signed out automatically."
         )
         |> assign_password_form()}

      {:error, form} ->
        {:noreply, assign(socket, :password_form, to_form(form))}
    end
  end

  # ── Trader profile handlers ────────────────────────────────────────

  def handle_event("validate_trading_profile", %{"form" => params}, socket) do
    params =
      params
      |> filter_empty_array_values()
      |> ensure_user_id(socket.assigns.trading_profile, socket.assigns.current_user)

    form = AshPhoenix.Form.validate(socket.assigns.trading_profile_form.source, params)
    {:noreply, assign(socket, :trading_profile_form, to_form(form))}
  end

  def handle_event("save_trading_profile", %{"form" => params}, socket) do
    params =
      params
      |> filter_empty_array_values()
      |> ensure_user_id(socket.assigns.trading_profile, socket.assigns.current_user)

    case AshPhoenix.Form.submit(socket.assigns.trading_profile_form.source, params: params) do
      {:ok, profile} ->
        {:noreply,
         socket
         |> put_flash(:info, "Trader profile updated.")
         |> assign(:trading_profile, profile)
         |> assign_trading_profile_form()}

      {:error, form} ->
        {:noreply, assign(socket, :trading_profile_form, to_form(form))}
    end
  end

  # ── Render ─────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user} current_path={@current_path}>
      <div class="max-w-2xl space-y-4">
        <h1 class="text-2xl font-bold mb-4">Profile</h1>

        <.personal_info_card
          form={@personal_info_form}
          user={@current_user}
          profile={@user_profile}
        />

        <.password_card form={@password_form} />

        <.trading_profile_card
          form={@trading_profile_form}
          profile={@trading_profile}
        />
      </div>
    </Layouts.app>
    """
  end

  # ── Section: Personal info ─────────────────────────────────────────

  attr :form, :any, required: true
  attr :user, :map, required: true
  attr :profile, :any, required: true

  defp personal_info_card(assigns) do
    ~H"""
    <section id="profile-personal-info" class="card bg-base-200 border border-base-300 p-4">
      <h2 class="font-semibold mb-3">Personal info</h2>

      <.form
        for={@form}
        id="personal-info-form"
        phx-change="validate_personal_info"
        phx-submit="save_personal_info"
        class="space-y-2"
      >
        <div class="flex items-center gap-4 mb-3">
          <.avatar_preview
            url={@form[:avatar_url].value}
            name={@form[:full_name].value}
            email={@user.email}
          />
          <p class="text-xs opacity-60">Paste an image URL below to set an avatar.</p>
        </div>

        <.input field={@form[:full_name]} type="text" label="Full name" />

        <.input
          type="text"
          name="email"
          id="email"
          value={to_string(@user.email)}
          label="Email"
          disabled
        />

        <.input field={@form[:phone]} type="text" label="Phone" />

        <.input field={@form[:avatar_url]} type="text" label="Avatar URL" />

        <button type="submit" class="btn btn-primary btn-sm mt-2">Save</button>
      </.form>
    </section>
    """
  end

  attr :url, :any, required: true
  attr :name, :any, required: true
  attr :email, :any, required: true

  defp avatar_preview(%{url: url} = assigns) when is_binary(url) and url != "" do
    ~H"""
    <img src={@url} alt="Avatar" class="size-12 rounded-full object-cover bg-base-300" />
    """
  end

  defp avatar_preview(assigns) do
    ~H"""
    <div class="size-12 rounded-full bg-primary text-primary-content flex items-center justify-center font-bold">
      {avatar_initials(@name, @email)}
    </div>
    """
  end

  defp avatar_initials(name, email) do
    cond do
      is_binary(name) and String.trim(name) != "" ->
        name |> String.trim() |> String.first() |> String.upcase()

      true ->
        email |> to_string() |> String.first() |> String.upcase()
    end
  end

  # ── Section: Change password ───────────────────────────────────────

  attr :form, :any, required: true

  defp password_card(assigns) do
    ~H"""
    <section id="profile-password" class="card bg-base-200 border border-base-300 p-4">
      <h2 class="font-semibold mb-3">Change password</h2>

      <.form
        for={@form}
        id="password-form"
        phx-change="validate_password"
        phx-submit="save_password"
        class="space-y-2"
      >
        <.input
          field={@form[:current_password]}
          type="password"
          label="Current password"
          phx-debounce="500"
        />
        <.input field={@form[:password]} type="password" label="New password" phx-debounce="500" />
        <.input
          field={@form[:password_confirmation]}
          type="password"
          label="Confirm new password"
          phx-debounce="500"
        />

        <button type="submit" class="btn btn-primary btn-sm mt-2">Update password</button>
        <p class="text-xs opacity-60 mt-2">
          Updating your password signs you out of all other browser sessions.
        </p>
      </.form>
    </section>
    """
  end

  # ── Section: Trader profile ────────────────────────────────────────

  attr :form, :any, required: true
  attr :profile, :any, required: true

  defp trading_profile_card(assigns) do
    style = current_trading_style(assigns.form)
    momentum? = style == :momentum_day
    assigns = assign(assigns, :momentum?, momentum?)

    ~H"""
    <section id="profile-trader" class="card bg-base-200 border border-base-300 p-4">
      <h2 class="font-semibold mb-3">Trader profile</h2>

      <p :if={is_nil(@profile)} class="text-sm opacity-70 mb-3">
        First time? Pick your trading style and time horizon below — the AI
        analyzer uses them to frame news for how you actually trade.
      </p>

      <.form
        for={@form}
        id="trading-profile-form"
        phx-change="validate_trading_profile"
        phx-submit="save_trading_profile"
        class="space-y-3"
      >
        <.input
          field={@form[:trading_style]}
          type="select"
          label="Trading style"
          prompt="Select one..."
          options={trading_styles()}
        />

        <.input
          field={@form[:time_horizon]}
          type="select"
          label="Time horizon"
          prompt="Select one..."
          options={time_horizons()}
        />

        <.checkbox_group
          field={@form[:market_cap_focuses]}
          label="Market cap focuses"
          options={market_caps()}
        />

        <.checkbox_group
          field={@form[:catalyst_preferences]}
          label="Catalyst preferences"
          options={catalysts()}
        />

        <.input field={@form[:notes]} type="textarea" label="Notes" />

        <div :if={@momentum?} class="space-y-2 border-t border-base-300 pt-3 mt-3">
          <p class="text-xs opacity-60">
            Momentum-style fields — used to filter and frame small-cap analysis.
          </p>

          <div class="grid grid-cols-2 gap-2">
            <.input field={@form[:price_min]} type="number" step="0.01" label="Price min" />
            <.input field={@form[:price_max]} type="number" step="0.01" label="Price max" />
          </div>

          <.input field={@form[:float_max]} type="number" label="Float max (shares)" />
        </div>

        <button type="submit" class="btn btn-primary btn-sm mt-2">Save trader profile</button>
      </.form>
    </section>
    """
  end

  attr :field, Phoenix.HTML.FormField, required: true
  attr :label, :string, required: true
  attr :options, :list, required: true

  defp checkbox_group(assigns) do
    selected = normalize_selected(assigns.field.value)
    assigns = assign(assigns, :selected, selected)

    ~H"""
    <fieldset class="fieldset mb-2">
      <legend class="label mb-1">{@label}</legend>
      <input type="hidden" name={"#{@field.name}[]"} value="" />
      <div class="grid grid-cols-2 sm:grid-cols-3 gap-x-4 gap-y-1">
        <label
          :for={{label, value} <- @options}
          class="flex items-center gap-2 cursor-pointer"
        >
          <input
            type="checkbox"
            name={"#{@field.name}[]"}
            value={to_string(value)}
            checked={to_string(value) in @selected}
            class="checkbox checkbox-sm"
          />
          <span class="text-sm">{label}</span>
        </label>
      </div>
    </fieldset>
    """
  end

  defp normalize_selected(nil), do: []
  defp normalize_selected(values) when is_list(values), do: Enum.map(values, &to_string/1)
  defp normalize_selected(value), do: [to_string(value)]

  # Drops "" entries from checkbox-group array params. The hidden empty
  # input is needed so unchecking everything still posts the field, but
  # AshPhoenix coerces "" to nil and the atom-array constraint rejects it.
  defp filter_empty_array_values(params) do
    Enum.reduce(~w(market_cap_focuses catalyst_preferences), params, fn key, acc ->
      case Map.get(acc, key) do
        list when is_list(list) -> Map.put(acc, key, Enum.reject(list, &(&1 == "")))
        _ -> acc
      end
    end)
  end

  # The :upsert action accepts user_id; the :update action does not. Inject
  # it only when we're creating a fresh profile so :update isn't fed an
  # extra field it would reject as `NoSuchInput`.
  defp ensure_user_id(params, nil, user), do: Map.put(params, "user_id", user.id)
  defp ensure_user_id(params, _profile, _user), do: params

  defp current_trading_style(form) do
    case form[:trading_style].value do
      style when is_atom(style) -> style
      style when is_binary(style) -> safe_to_atom(style)
      _ -> nil
    end
  end

  defp safe_to_atom(value) do
    Enum.find_value(@trading_styles, fn {_label, atom} ->
      if to_string(atom) == value, do: atom
    end)
  end

  defp trading_styles, do: @trading_styles
  defp time_horizons, do: @time_horizons
  defp market_caps, do: @market_caps
  defp catalysts, do: @catalysts
end
