defmodule FinanceSmithWeb.ErrorHTML do
  use FinanceSmithWeb, :html

  def render("404.html", _assigns) do
    assigns = %{}

    ~H"""
    <!DOCTYPE html>
    <html lang="en" class="dark">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <title>404 · Finance Smith</title>
      </head>
      <body class="bg-black text-gray-100 min-h-screen flex items-center justify-center">
        <main class="text-center max-w-md border border-gray-800 bg-gray-950 p-8 rounded-lg">
          <p class="text-[10px] font-mono text-gray-500 uppercase tracking-widest mb-4">404</p>
          <h1 class="text-lg font-mono text-gray-100">There is no data here. Only an anomaly.</h1>
          <p class="mt-4 text-sm text-gray-400 font-mono">The requested resource does not exist.</p>
          <a href="/" class="mt-6 inline-block text-xs font-mono text-gray-500 hover:text-emerald-500 border border-gray-800 hover:border-gray-700 px-4 py-2 transition-colors">
            Return to the ledger
          </a>
        </main>
      </body>
    </html>
    """
  end

  def render("500.html", _assigns) do
    assigns = %{}

    ~H"""
    <!DOCTYPE html>
    <html lang="en" class="dark">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <title>500 · Finance Smith</title>
      </head>
      <body class="bg-black text-gray-100 min-h-screen flex items-center justify-center">
        <main class="text-center max-w-md border border-gray-800 bg-gray-950 p-8 rounded-lg">
          <p class="text-[10px] font-mono text-gray-500 uppercase tracking-widest mb-4">500</p>
          <h1 class="text-lg font-mono text-gray-100">We have a... discrepancy.</h1>
          <p class="mt-4 text-sm text-gray-400 font-mono">An internal error has occurred.</p>
          <a href="/" class="mt-6 inline-block text-xs font-mono text-gray-500 hover:text-emerald-500 border border-gray-800 hover:border-gray-700 px-4 py-2 transition-colors">
            Return to the ledger
          </a>
        </main>
      </body>
    </html>
    """
  end

  def render(template, _assigns) do
    Phoenix.Controller.status_message_from_template(template)
  end
end
