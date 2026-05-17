defmodule LongOrShortWeb.PlaybookEditLive do
  @moduledoc """
  Form-based editor for `Trading.Playbook` (LON-184, TW-4 of [[LON-180]]).

  Lives at `/playbook/edit`. Reached deliberately from `/playbook`'s
  Edit button or directly via URL. Sister page is the read-only
  `PlaybookLive`; the split keeps mutation gated behind explicit
  intent.

  ## What's editable

    * Create a new playbook: pick `kind` + `name` → empty items list
    * Per-playbook inline form: rename items, add new items, remove
      items. Save options:
        - **Save as new version** → `Trading.create_playbook_version/4`.
          3-version cap; over-cap returns an error pointing at the
          history view.
        - **Update current (no version bump)** → `Trading.update_playbook_items/2`.
          Existing item UUIDs round-trip via hidden state so
          `PlaybookCheckState.checked_items` survives the edit.
    * Version history per playbook: expand to view older versions,
      restore one (= create a new version with its items), delete an
      individual version.
    * Delete the whole playbook: cascades to all versions + check
      states via the DB FK (per LON-181 migration).

  ## State shape

  Per-playbook editing state lives in `@drafts` keyed by playbook id
  (or `:new` for the create-new form). Each draft:

      %{items: [%{id: uuid | nil, text: string}], save_mode: :new_version | :update_current}

  `id: nil` flags a freshly-added item that hasn't been persisted
  yet — server generates a UUID on save via the embed's default.

  ## Why socket assigns, not AshPhoenix.Form

  The "items list with add/remove rows" pattern doesn't map cleanly
  to AshPhoenix's nested forms without significant ceremony. State is
  just a list of `%{id, text}` maps; plain `phx-change` + `assign`
  handle it in ~50 LOC versus the form-helpers version.
  """

  use LongOrShortWeb, :live_view

  alias LongOrShort.Trading
  alias LongOrShort.Trading.Playbook

  @kinds [{"Daily rules", :rules}, {"Setup", :setup}]

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Edit playbook")
     |> assign(:new_form_open?, false)
     |> assign(:new_form, %{kind: :rules, name: ""})
     |> assign(:drafts, %{})
     |> assign(:history_open, MapSet.new())
     |> assign(:history_versions, %{})
     |> load_playbooks()}
  end

  # ── Render ──────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app current_path={@current_path} current_user={@current_user} flash={@flash}>
      <div class="max-w-3xl mx-auto space-y-6">
        <div class="flex items-center justify-between">
          <h1 class="text-2xl font-bold">Edit Playbook</h1>
          <.link navigate={~p"/playbook"} class="btn btn-ghost btn-sm">
            <.icon name="hero-arrow-left" class="size-4" /> Back
          </.link>
        </div>

        <.new_playbook_form open?={@new_form_open?} form={@new_form} />

        <.section
          title="Daily Rules"
          playbooks={Enum.filter(@playbooks, &(&1.kind == :rules))}
          drafts={@drafts}
          history_open={@history_open}
          history_versions={@history_versions}
        />

        <.section
          title="Setups"
          playbooks={Enum.filter(@playbooks, &(&1.kind == :setup))}
          drafts={@drafts}
          history_open={@history_open}
          history_versions={@history_versions}
        />

        <p :if={@playbooks == []} class="text-sm opacity-60 italic">
          No playbooks yet — use the form above to create your first one.
        </p>
      </div>
    </Layouts.app>
    """
  end

  attr :open?, :boolean, required: true
  attr :form, :map, required: true

  defp new_playbook_form(assigns) do
    assigns = assign(assigns, :kinds, @kinds)

    ~H"""
    <section class="card bg-base-200 border border-base-300 p-4">
      <%= if @open? do %>
        <form phx-submit="create_playbook" phx-change="new_form_change" class="space-y-3">
          <h3 class="font-semibold">New playbook</h3>

          <div class="flex gap-3">
            <select name="kind" class="select select-bordered select-sm">
              <option :for={{label, value} <- @kinds} value={value} selected={@form.kind == value}>
                {label}
              </option>
            </select>

            <input
              type="text"
              name="name"
              value={@form.name}
              placeholder='e.g. "Daily rules" or "Long setup"'
              class="input input-bordered input-sm flex-1"
              required
              maxlength="80"
              phx-debounce="300"
            />
          </div>

          <div class="flex justify-end gap-2">
            <button type="button" phx-click="toggle_new_form" class="btn btn-ghost btn-sm">
              Cancel
            </button>
            <button type="submit" class="btn btn-primary btn-sm" disabled={@form.name == ""}>
              Create
            </button>
          </div>
        </form>
      <% else %>
        <button type="button" phx-click="toggle_new_form" class="btn btn-outline btn-sm">
          <.icon name="hero-plus" class="size-4" /> New playbook
        </button>
      <% end %>
    </section>
    """
  end

  attr :title, :string, required: true
  attr :playbooks, :list, required: true
  attr :drafts, :map, required: true
  attr :history_open, :any, required: true
  attr :history_versions, :map, required: true

  defp section(assigns) do
    ~H"""
    <section :if={@playbooks != []} class="space-y-3">
      <h2 class="text-lg font-semibold opacity-80">{@title}</h2>
      <.editor
        :for={pb <- @playbooks}
        playbook={pb}
        draft={Map.get(@drafts, pb.id, default_draft(pb))}
        history_open?={MapSet.member?(@history_open, pb.id)}
        history={Map.get(@history_versions, pb.id, [])}
      />
    </section>
    """
  end

  attr :playbook, :any, required: true
  attr :draft, :map, required: true
  attr :history_open?, :boolean, required: true
  attr :history, :list, required: true

  defp editor(assigns) do
    ~H"""
    <section
      id={"playbook-#{@playbook.id}"}
      class="card bg-base-200 border border-base-300 p-4"
    >
      <div class="flex items-baseline justify-between mb-3">
        <h3 class="font-semibold">{@playbook.name}</h3>
        <span class="text-xs opacity-60">v{@playbook.version}</span>
      </div>

      <form
        phx-change={"draft_change:#{@playbook.id}"}
        phx-submit={"save_playbook:#{@playbook.id}"}
        class="space-y-2"
      >
        <ul class="space-y-2">
          <li
            :for={{item, idx} <- Enum.with_index(@draft.items)}
            class="flex items-center gap-2"
          >
            <input type="hidden" name={"items[#{idx}][id]"} value={item.id || ""} />
            <input
              type="text"
              name={"items[#{idx}][text]"}
              value={item.text}
              class="input input-bordered input-sm flex-1"
              maxlength="280"
              placeholder="Item text"
              phx-debounce="300"
            />
            <button
              type="button"
              phx-click={"remove_item:#{@playbook.id}:#{idx}"}
              class="btn btn-ghost btn-sm btn-circle"
              title="Remove item"
            >
              <.icon name="hero-x-mark" class="size-4" />
            </button>
          </li>
        </ul>

        <div class="flex items-center justify-between mt-3">
          <button
            type="button"
            phx-click={"add_item:#{@playbook.id}"}
            class="btn btn-ghost btn-sm"
          >
            <.icon name="hero-plus" class="size-4" /> Add item
          </button>

          <div class="flex items-center gap-2">
            <select name="save_mode" class="select select-bordered select-xs">
              <option value="new_version" selected={@draft.save_mode == :new_version}>
                Save as new version
              </option>
              <option value="update_current" selected={@draft.save_mode == :update_current}>
                Update current (no version bump)
              </option>
            </select>
            <button type="submit" class="btn btn-primary btn-sm">Save</button>
          </div>
        </div>
      </form>

      <div class="flex items-center justify-between mt-4 pt-3 border-t border-base-300">
        <button
          type="button"
          phx-click={"toggle_history:#{@playbook.id}"}
          class="text-xs link link-hover opacity-70"
        >
          {if @history_open?, do: "Hide", else: "View"} previous versions
        </button>

        <button
          type="button"
          phx-click={"delete_playbook:#{@playbook.id}"}
          data-confirm={"Delete '#{@playbook.name}' entirely? Removes all versions AND today's check states. Cannot be undone."}
          class="text-xs link link-hover text-error opacity-70"
        >
          Delete playbook
        </button>
      </div>

      <div :if={@history_open?} class="mt-3 space-y-2">
        <p :if={@history == []} class="text-xs opacity-60 italic">
          No previous versions — this is the only one.
        </p>

        <article
          :for={v <- @history}
          class="bg-base-100 border border-base-300 rounded p-3 text-sm"
        >
          <div class="flex items-baseline justify-between mb-2">
            <span class="font-semibold">v{v.version}</span>
            <span class="text-xs opacity-60">
              {DateTime.to_date(v.inserted_at) |> Date.to_string()}
            </span>
          </div>

          <ul class="space-y-1 text-xs opacity-80">
            <li :for={item <- v.items} class="flex items-start gap-1">
              <span class="opacity-50">•</span>
              <span>{item.text}</span>
            </li>
          </ul>

          <div class="flex justify-end gap-2 mt-2">
            <button
              type="button"
              phx-click={"restore_version:#{v.id}"}
              class="btn btn-ghost btn-xs"
            >
              Restore
            </button>
            <button
              type="button"
              phx-click={"delete_version:#{v.id}"}
              data-confirm={"Delete version #{v.version}? Cannot be undone."}
              class="btn btn-ghost btn-xs text-error"
            >
              Delete
            </button>
          </div>
        </article>
      </div>
    </section>
    """
  end

  # ── Event handlers ──────────────────────────────────────────────

  @impl true
  def handle_event("toggle_new_form", _, socket) do
    {:noreply,
     socket
     |> update(:new_form_open?, &(!&1))
     |> assign(:new_form, %{kind: :rules, name: ""})}
  end

  def handle_event("new_form_change", %{"kind" => kind, "name" => name}, socket) do
    {:noreply, assign(socket, :new_form, %{kind: parse_kind(kind), name: name})}
  end

  def handle_event("create_playbook", %{"kind" => kind, "name" => name}, socket) do
    user_id = socket.assigns.current_user.id
    name = String.trim(name)

    # `authorize?: false` — Ash 3.x can't evaluate the `expr(user_id ==
    # ^actor(:id))` policy on `:create` actions (no row yet). UI enforces
    # ownership: `user_id` is set from `socket.assigns.current_user.id`,
    # never from form input. Same pattern carried from LON-181.
    case Trading.create_playbook_version(user_id, parse_kind(kind), name, [],
           authorize?: false
         ) do
      {:ok, _pb} ->
        {:noreply,
         socket
         |> put_flash(:info, "Created '#{name}'.")
         |> assign(:new_form_open?, false)
         |> assign(:new_form, %{kind: :rules, name: ""})
         |> load_playbooks()}

      {:error, error} ->
        {:noreply, put_flash(socket, :error, format_error(error))}
    end
  end

  def handle_event("draft_change:" <> pb_id, params, socket) do
    items = parse_items_form(params["items"] || %{})
    save_mode = parse_save_mode(params["save_mode"])

    {:noreply,
     update(socket, :drafts, fn drafts ->
       Map.put(drafts, pb_id, %{items: items, save_mode: save_mode})
     end)}
  end

  def handle_event("add_item:" <> pb_id, _, socket) do
    pb = find_playbook!(socket, pb_id)
    draft = Map.get(socket.assigns.drafts, pb_id, default_draft(pb))
    new_items = draft.items ++ [%{id: nil, text: ""}]

    {:noreply,
     update(socket, :drafts, fn drafts ->
       Map.put(drafts, pb_id, %{draft | items: new_items})
     end)}
  end

  def handle_event("remove_item:" <> rest, _, socket) do
    [pb_id, idx_str] = String.split(rest, ":", parts: 2)
    idx = String.to_integer(idx_str)
    pb = find_playbook!(socket, pb_id)
    draft = Map.get(socket.assigns.drafts, pb_id, default_draft(pb))
    new_items = List.delete_at(draft.items, idx)

    {:noreply,
     update(socket, :drafts, fn drafts ->
       Map.put(drafts, pb_id, %{draft | items: new_items})
     end)}
  end

  def handle_event("save_playbook:" <> pb_id, params, socket) do
    pb = find_playbook!(socket, pb_id)
    items = parse_items_form(params["items"] || %{})
    save_mode = parse_save_mode(params["save_mode"])

    items_payload = Enum.map(items, &item_for_payload/1)
    actor = socket.assigns.current_user

    result =
      case save_mode do
        :new_version ->
          # `authorize?: false` for the same reason as `create_playbook` —
          # Ash 3.x can't filter-authorize creates. user_id round-trips
          # via `pb.user_id`, which was loaded under actor auth.
          Trading.create_playbook_version(pb.user_id, pb.kind, pb.name, items_payload,
            authorize?: false
          )

        :update_current ->
          pb
          |> Ash.Changeset.for_update(:update_items, %{items: items_payload}, actor: actor)
          |> Ash.update()
      end

    case result do
      {:ok, _saved} ->
        {:noreply,
         socket
         |> put_flash(:info, "Saved.")
         |> update(:drafts, &Map.delete(&1, pb_id))
         |> load_playbooks()
         |> refresh_history(pb_id)}

      {:error, error} ->
        {:noreply, put_flash(socket, :error, format_error(error))}
    end
  end

  def handle_event("toggle_history:" <> pb_id, _, socket) do
    open = socket.assigns.history_open

    if MapSet.member?(open, pb_id) do
      {:noreply,
       socket
       |> assign(:history_open, MapSet.delete(open, pb_id))
       |> update(:history_versions, &Map.delete(&1, pb_id))}
    else
      {:noreply,
       socket
       |> assign(:history_open, MapSet.put(open, pb_id))
       |> load_history(pb_id)}
    end
  end

  def handle_event("restore_version:" <> version_id, _, socket) do
    actor = socket.assigns.current_user

    with {:ok, source} <- Trading.get_playbook(version_id, actor: actor),
         items_payload = Enum.map(source.items, &%{text: &1.text}),
         {:ok, _new} <-
           Trading.create_playbook_version(
             source.user_id,
             source.kind,
             source.name,
             items_payload,
             # See `create_playbook` for the Ash 3.x create-policy note.
             # `source` was loaded under actor auth, so user_id is trusted.
             authorize?: false
           ) do
      {:noreply,
       socket
       |> put_flash(:info, "Restored v#{source.version} as a new version.")
       |> load_playbooks()
       |> refresh_history_by_chain(source)}
    else
      {:error, error} ->
        {:noreply, put_flash(socket, :error, format_error(error))}
    end
  end

  def handle_event("delete_version:" <> version_id, _, socket) do
    actor = socket.assigns.current_user

    case Trading.get_playbook(version_id, actor: actor) do
      {:ok, %Playbook{} = pb} ->
        case Ash.destroy(pb, actor: actor) do
          :ok ->
            {:noreply,
             socket
             |> put_flash(:info, "Deleted v#{pb.version}.")
             |> load_playbooks()
             |> refresh_history_by_chain(pb)}

          {:error, error} ->
            {:noreply, put_flash(socket, :error, format_error(error))}
        end

      _ ->
        {:noreply, put_flash(socket, :error, "Version not found.")}
    end
  end

  def handle_event("delete_playbook:" <> pb_id, _, socket) do
    actor = socket.assigns.current_user
    pb = find_playbook!(socket, pb_id)

    # Delete the entire chain — every version row for (user, kind, name)
    {:ok, all_versions} =
      Trading.list_playbook_versions(pb.user_id, pb.kind, pb.name, actor: actor)

    Enum.each(all_versions, &Ash.destroy!(&1, actor: actor))

    {:noreply,
     socket
     |> put_flash(:info, "Deleted '#{pb.name}' and all #{length(all_versions)} version(s).")
     |> update(:drafts, &Map.delete(&1, pb_id))
     |> update(:history_open, &MapSet.delete(&1, pb_id))
     |> update(:history_versions, &Map.delete(&1, pb_id))
     |> load_playbooks()}
  end

  # ── Internals ───────────────────────────────────────────────────

  defp load_playbooks(socket) do
    actor = socket.assigns.current_user

    playbooks =
      case Trading.list_active_playbooks(actor.id, actor: actor) do
        {:ok, list} -> list
        _ -> []
      end

    assign(socket, :playbooks, playbooks)
  end

  defp load_history(socket, pb_id) do
    pb = find_playbook!(socket, pb_id)
    actor = socket.assigns.current_user

    case Trading.list_playbook_versions(pb.user_id, pb.kind, pb.name, actor: actor) do
      {:ok, versions} ->
        # Exclude the currently-active version — that's already shown
        # in the editor above. History panel = older entries only.
        older = Enum.reject(versions, &(&1.id == pb.id))
        update(socket, :history_versions, &Map.put(&1, pb_id, older))

      _ ->
        socket
    end
  end

  # After mutations that may shift the active row id (restore creates a
  # new version which becomes active), the previously-open history
  # entry's key may no longer correspond to a current playbook. Drop
  # stale entries; re-fetch for ones that still apply.
  defp refresh_history(socket, pb_id) do
    if MapSet.member?(socket.assigns.history_open, pb_id) do
      load_history(socket, pb_id)
    else
      socket
    end
  end

  defp refresh_history_by_chain(socket, %Playbook{user_id: uid, kind: k, name: n}) do
    # Find the active playbook for this chain; refresh history under
    # its id if open.
    current = Enum.find(socket.assigns.playbooks, &(&1.user_id == uid and &1.kind == k and &1.name == n))

    case current do
      nil -> socket
      %{id: id} -> refresh_history(socket, id)
    end
  end

  defp parse_items_form(items_params) when is_map(items_params) do
    items_params
    |> Enum.sort_by(fn {idx_str, _} -> String.to_integer(idx_str) end)
    |> Enum.map(fn {_idx, %{"id" => id, "text" => text}} ->
      %{id: blank_to_nil(id), text: text}
    end)
  end

  defp parse_items_form(_), do: []

  # New items have `id: nil` — strip the key so the embed default
  # (server-generated UUID v7) kicks in. Existing items keep their
  # UUID so check states survive the edit.
  defp item_for_payload(%{id: nil, text: text}), do: %{text: text}
  defp item_for_payload(%{id: id, text: text}), do: %{id: id, text: text}

  defp default_draft(%Playbook{items: items}) do
    %{
      items: Enum.map(items, &%{id: &1.id, text: &1.text}),
      save_mode: :new_version
    }
  end

  defp parse_kind("rules"), do: :rules
  defp parse_kind("setup"), do: :setup
  defp parse_kind(other) when is_atom(other), do: other

  defp parse_save_mode("update_current"), do: :update_current
  defp parse_save_mode(_), do: :new_version

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(s) when is_binary(s), do: s
  defp blank_to_nil(_), do: nil

  defp find_playbook!(socket, pb_id) do
    Enum.find(socket.assigns.playbooks, &(&1.id == pb_id)) ||
      raise "Playbook #{pb_id} not in current user's active list"
  end

  defp format_error(%Ash.Error.Invalid{errors: errors}) do
    errors
    |> Enum.map_join("; ", &error_message/1)
  end

  defp format_error(other), do: inspect(other)

  defp error_message(%Ash.Error.Changes.InvalidChanges{message: msg}) when is_binary(msg), do: msg
  defp error_message(%{message: msg}) when is_binary(msg), do: msg
  defp error_message(other), do: inspect(other)
end
