defmodule FinanceSmithWeb.ErrorHTML do
  use FinanceSmithWeb, :html

  def render(template, _assigns) do
    Phoenix.Controller.status_message_from_template(template)
  end

  def html(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html lang="en" class="dark">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <title>Error · Finance Smith</title>
      </head>
      <body class="bg-gray-950 text-gray-100 min-h-screen flex items-center justify-center">
        <main class="text-center max-w-md border border-gray-800 bg-gray-950 p-8 rounded-lg">
          <h1 class="text-lg font-mono text-emerald-500">We have a... discrepancy.</h1>
          <p class="mt-4 text-sm text-gray-400 font-mono"><%= @exception.message %></p>
        </main>
      </body>
    </html>
    """
  end
end
