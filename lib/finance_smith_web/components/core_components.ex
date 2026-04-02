defmodule FinanceSmithWeb.CoreComponents do
  @moduledoc """
  Core components used across the app. Petal Components are used via `use PetalComponents` in the web module.
  """
  use Phoenix.Component
  import PetalComponents.Alert

  attr(:flash, :map, required: true)

  def flash_group(assigns) do
    ~H"""
    <div :if={map_size(@flash) > 0} id="flash-group" class="mb-6 space-y-2">
      <%= for {kind, message} <- @flash do %>
        <.alert
          id={"flash-#{kind}"}
          color={if kind == "error", do: "danger", else: "success"}
          with_icon
          label={message}
          close_button_properties={["phx-click": "lv:clear-flash", "phx-value-key": kind]}
        />
      <% end %>
    </div>
    """
  end

  attr(:rest, :global)
  slot(:inner_block, required: true)

  def error(assigns) do
    ~H"""
    <p class="text-sm text-red-400 font-mono" {@rest}><%= render_slot(@inner_block) %></p>
    """
  end
end
