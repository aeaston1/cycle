defmodule Cycle.Version do
  @moduledoc false

  @version Mix.Project.config()[:version]

  def current, do: @version
end
