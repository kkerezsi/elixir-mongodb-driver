defmodule Mongo.MongoDBConnection do
  @moduledoc """
  Implementation of the DBConnection behaviour module.
  """

  require Logger

  use DBConnection
  use Mongo.Messages

  ## todo import Keywords

  alias Mongo.Events
  alias Mongo.Events.CommandStartedEvent
  alias Mongo.MongoDBConnection.Utils
  alias Mongo.Events.MoreToComeEvent

  @timeout        5_000
  @find_one_flags ~w(slave_ok exhaust partial)a
  @write_concern  ~w(w j wtimeout)a

  @impl true
  def connect(opts) do

    {write_concern, opts} = Keyword.split(opts, @write_concern)
    write_concern = Keyword.put_new(write_concern, :w, 1)

    state = %{
      connection: nil,
      request_id: 0,
      timeout: opts[:timeout] || @timeout,
      connect_timeout: opts[:connect_timeout] || @timeout,
      database: Keyword.fetch!(opts, :database),
      write_concern: Map.new(write_concern),
      wire_version: 0,
      auth_mechanism: opts[:auth_mechanism] || nil,
      connection_type: Keyword.fetch!(opts, :connection_type),
      topology_pid: Keyword.fetch!(opts, :topology_pid),
      ssl: opts[:ssl] || opts[:tls] || false
    }

    connect(opts, state)
  end

  @impl true
  def disconnect(_error, %{connection: {mod, socket}} = state) do
    notify_disconnect(state)
    mod.close(socket)
    :ok
  end

  defp notify_disconnect(%{connection_type: type, topology_pid: pid, host: host}) do
    GenServer.cast(pid, {:disconnect, type, host})
  end

  defp connect(opts, state) do

    result =
      with {:ok, state} <- tcp_connect(opts, state),
           {:ok, state} <- maybe_ssl(opts, state),
           {:ok, state} <- hand_shake(opts, state),
           {:ok, state} <- maybe_auth(opts, state) do
        {:ok, state}
      end

    case result do
      {:ok, state} ->
        {:ok, state}

      {:disconnect, reason, state} ->
        reason = case reason do
          {:tcp_recv, reason} -> Mongo.Error.exception(tag: :tcp, action: "recv", reason: reason, host: state.host)
          {:tcp_send, reason} -> Mongo.Error.exception(tag: :tcp, action: "send", reason: reason, host: state.host)
          %Mongo.Error{} = reason -> reason
        end
        {mod, socket} = state.connection
        mod.close(socket)
        {:error, reason}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp maybe_auth(opts, state) do
    case opts[:skip_auth] do
      true -> {:ok, state}
      _    -> Mongo.Auth.run(opts, state)
    end
  end

  defp maybe_ssl(opts, %{ssl: true} = state), do: ssl(opts, state)
  defp maybe_ssl(_opts, state), do: {:ok, state}

  defp ssl(opts, %{connection: {:gen_tcp, socket}} = state) do
    host     = (opts[:hostname] || "localhost") |> to_charlist
    ssl_opts = Keyword.put_new(opts[:ssl_opts] || [], :server_name_indication, host)
    case :ssl.connect(socket, ssl_opts, state.connect_timeout) do
      {:ok, ssl_sock}  -> {:ok, %{state | connection: {:ssl, ssl_sock}}}
      {:error, reason} ->
        :gen_tcp.close(socket)
        {:error, Mongo.Error.exception(tag: :ssl, action: "connect", reason: reason, host: state.host)}
    end
  end

  defp tcp_connect(opts, s) do
    {host, port} = Utils.hostname_port(opts)
    sock_opts   = [:binary, active: false, packet: :raw, nodelay: true] ++ (opts[:socket_options] || [])

    s = case host do
      {:local, socket} -> Map.put(s, :host, socket)
      hostname         -> Map.put(s, :host, "#{hostname}:#{port}")
    end

    case :gen_tcp.connect(host, port, sock_opts, s.connect_timeout) do
      {:ok, socket} ->
        # A suitable :buffer is only set if :recbuf is included in
        # :socket_options.
        {:ok, [sndbuf: sndbuf, recbuf: recbuf, buffer: buffer]} = :inet.getopts(socket, [:sndbuf, :recbuf, :buffer])
        buffer = buffer
                 |> max(sndbuf)
                 |> max(recbuf)

        :ok = :inet.setopts(socket, buffer: buffer)

        {:ok, %{s | connection: {:gen_tcp, socket}}}

      {:error, reason} -> {:error, Mongo.Error.exception(tag: :tcp, action: "connect", reason: reason, host: s.host)}
    end
  end

  defp wire_version(state, client) do
    # wire version
    # https://github.com/mongodb/mongo/blob/master/src/mongo/db/wire_version.h

    cmd = [ismaster: 1, client: client]

    case Utils.command(-1, cmd, state) do
      {:ok, _flags, %{"ok" => ok, "maxWireVersion" => version}}  when ok == 1 -> {:ok, %{state | wire_version: version}}
      {:ok, _flags, %{"ok" => ok}} when ok == 1 ->  {:ok, %{state | wire_version: 0}}
      {:ok, _flags, %{"ok" => ok, "errmsg" => msg, "code" => code}} when ok == 0 ->
        err = Mongo.Error.exception(message: msg, code: code)
        {:disconnect, err, state}
      {:disconnect, _, _} = error ->   error
    end
  end

  defp hand_shake(opts, state) do
    wire_version(state, driver(opts[:appname] || "My killer app"))
  end

  defp driver(appname) do

    driver_version = case :application.get_key(:mongodb_driver, :vsn) do
      {:ok, version} -> to_string(version)
      _              -> "??"
    end

    {architecture, name} = get_architecture()

    version = case :os.version() do
      {one, two, tree} -> to_string(one) <> "." <> to_string(two) <> "." <> to_string(tree)
      s                -> s
    end

    platform = "Elixir (" <> System.version() <> "), Erlang/OTP (" <> to_string(:erlang.system_info(:otp_release)) <> "), ERTS (" <> to_string(:erlang.system_info(:version)) <> ")"

    type = elem(:os.type(), 1)
    %{
      client: %{
        application: %{name: appname}
      },
      driver: %{
        name: "mongodb_driver",
        version: driver_version
      },
      os: %{
        type: type,
        name: pretty_name(name),
        architecture: architecture,
        version: version
      },
      platform: platform
    }
  end

  defp get_architecture() do
    case String.split(to_string(:erlang.system_info(:system_architecture)), "-") do
      [architecture, name | _rest] -> {architecture, name}
      ["win32"]                    -> {"win32", "Windows"}
      [one]                        -> {"??", one}
      []                           -> {"??", "??"}
    end
  end

  defp pretty_name("apple"), do: "Mac OS X"
  defp pretty_name(name), do: name

  @impl true
  def checkout(state), do: {:ok, state}
  @impl true
  def checkin(state), do: {:ok, state}

  @impl true
  def handle_begin(_opts, state), do: {:ok, nil, state}
  @impl true
  def handle_close(_query, _opts, state), do: {:ok, nil, state}
  @impl true
  def handle_commit(_opts, state), do: {:ok, nil, state}
  @impl true
  def handle_deallocate(_query, _cursor, _opts, state), do:  {:ok, nil, state}
  @impl true
  def handle_declare(query, _params, _opts, state), do: {:ok, query, nil, state}
  @impl true
  def handle_fetch(_query, _cursor, _opts, state), do: {:halt, nil, state}
  @impl true
  def handle_prepare(query, _opts, state), do: {:ok, query, state}
  @impl true
  def handle_rollback(_opts, state), do: {:ok, nil, state}
  @impl true
  def handle_status(_opts, state), do: {:idle, state}

  @impl true
  def ping(%{wire_version: _wire_version} = state) do
    ###with {:ok, %{wire_version: ^wire_version}} <- wire_version(state), do: {:ok, state}
    ## Logger.info("Ignoring ping")
    {:ok, state}
  end

  @doc """
  Execute a query prepared by `c:handle_prepare/3`. Return
  `{:ok, query, result, state}` to return altered query `query` and result
  `result` and continue, `{:error, exception, state}` to return an error and
  continue or `{:disconnect, exception, state}` to return an error and
  disconnect.

  This callback is called in the client process.
  """
  def handle_execute_close(query, params, opts, s) do
    handle_execute(query, params, opts, s)
  end

  @impl true
  def handle_execute(%Mongo.Query{action: action} = query, params, opts, original_state) do
    tmp_state = %{original_state | database: Keyword.get(opts, :database, original_state.database)}
    with {:ok, reply, tmp_state} <- execute_action(action, params, opts, tmp_state) do
      {:ok, query, reply, Map.put(tmp_state, :database, original_state.database)}
    end
  end

  @insecure_cmds [:authenticate, :saslStart, :saslContinue, :getnonce, :createUser, :updateUser, :copydbgetnonce, :copydbsaslstart, :copydb, :isMaster, :ismaster]
  defp provide_cmd_data([{command_name,_}|_] = cmd) do
    case Enum.member?(@insecure_cmds, command_name) do
      true  -> {command_name, %{}}
      false -> {command_name, cmd}
    end
  end

  ##
  # Executes a more to come command
  ##
  defp execute_action(:command, [:more_to_come], opts, %{wire_version: version} = state) when version >= 6 do

    event = %MoreToComeEvent{command: :more_to_come, command_name: opts[:command_name] || :more_to_come}

    timeout = Keyword.get(opts, :timeout, state.timeout)

    Events.notify(event, :commands)

    with {duration, {:ok, flags, doc}} <- :timer.tc(fn -> Utils.get_response(state.request_id, %{state | timeout: timeout}) end)do
      Logger.info("more_to_come-Response: flags: #{inspect  Integer.to_string(flags, 2)} and docs #{inspect doc}")
      {:ok, {doc, event, flags, duration}, state}
    else
      {_duration, error} ->
        Logger.info("More to come error")
        error
    end
  end

  defp execute_action(:command, [cmd], opts, %{wire_version: version} = state) when version >= 6 do

    {command_name, data} = provide_cmd_data(cmd)
    db                   = opts[:database] || state.database
    cmd                  = cmd ++ ["$db": db]
    flags                = Keyword.get(opts, :flags, 0x0)

    # MongoDB 3.6 only allows certain command arguments to be provided this way. These are:
    op = case pulling_out?(cmd, :documents) || pulling_out?(cmd, :updates) || pulling_out?(cmd, :deletes) do
      nil -> op_msg(flags: flags, sections: [section(payload_type: 0, payload: payload(doc: cmd))])
      key -> pulling_out(cmd, flags, key)
    end

    # overwrite temporary timeout by timeout option
    timeout = Keyword.get(opts, :timeout, state.timeout)

    event = %CommandStartedEvent{
            command: data,
            command_name: opts[:command_name] || command_name,
            database_name: db,
            request_id: state.request_id,
            operation_id: opts[:operation_id],
            connection_id: self()}

    Events.notify(event, :commands)

    with {duration, {:ok, flags, doc}} <- :timer.tc(fn -> Utils.post_request(op, state.request_id, %{state | timeout: timeout}) end),
         state = %{state | request_id: state.request_id + 1} do
      Logger.info("Post-Request ok")
      {:ok, {doc, event, flags, duration}, state}
    else
      {_duration, error} ->
      Logger.info("Post-Request error")
        error
    end
  end

  defp execute_action(:command, [cmd], opts, state) do

    [{command_name,_}|_] = cmd
    event = %CommandStartedEvent{
      command: cmd,
      command_name: opts[:command_name] || command_name,
      database_name: opts[:database] || state.database,
      request_id: state.request_id,
      operation_id: opts[:operation_id],
      connection_id: self()}

    flags    = Keyword.take(opts, @find_one_flags)
    op       = op_query(coll: Utils.namespace("$cmd", state, opts[:database]), query: cmd, select: "", num_skip: 0, num_return: 1, flags: flags(flags))
    timeout  = Keyword.get(opts, :timeout, state.timeout)
    with {duration, {:ok, flags, doc}} <- :timer.tc(fn -> Utils.post_request(op, state.request_id, %{state | timeout: timeout}) end),
         state = %{state | request_id: state.request_id + 1}  do
      {:ok, {doc, event, flags, duration}, state}
    else
      {_duration, error} ->
        error
    end
  end

  defp execute_action(:error, _query, _opts, state) do
    exception = Mongo.Error.exception("Test-case")
    {:disconnect, exception, state}
  end

  defp pulling_out?(cmd, key) do
    case Keyword.has_key?(cmd, key) do
      true  -> key
      false -> nil
    end
  end

  defp pulling_out(cmd, flags, key) when is_atom(key) do

    docs = Keyword.get(cmd, key)
    cmd  = Keyword.delete(cmd, key)

    payload_0 = section(payload_type: 0, payload: payload(doc: cmd))
    payload_1 = section(payload_type: 1, payload: payload(sequence: sequence(identifier: to_string(key), docs: docs)))

    op_msg(flags: flags, sections: [payload_0, payload_1])
  end

  defp flags(flags) do
    Enum.reduce(flags, [], fn
      {flag, true},   acc -> [flag|acc]
      {_flag, false}, acc -> acc
    end)
  end

end
