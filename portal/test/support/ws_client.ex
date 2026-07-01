defmodule Onlytty.WSClient do
  @moduledoc """
  A tiny raw WebSocket test client. It drives the relay over real HTTP/1.1
  WebSockets so tests exercise the actual Bandit + WebSock path, not a mock.
  """

  import Bitwise
  import ExUnit.Assertions

  defstruct [:socket, :ref, :port]

  @host {127, 0, 0, 1}

  @doc "Open a TCP connection to the test endpoint."
  def open(port) do
    {:ok, socket} = :gen_tcp.connect(@host, port, [:binary, active: false, packet: :raw], 5000)
    %__MODULE__{socket: socket, ref: make_ref(), port: port}
  end

  @doc """
  Upgrade `path` to a WebSocket. Returns `{:ok, ref}` on success or `{:error, status}` if
  the server rejected the handshake with an HTTP status (our 401 / 404 rejection path).
  """
  def upgrade(%__MODULE__{} = client, path, headers \\ []) do
    key = :crypto.strong_rand_bytes(16) |> Base.encode64()

    request = [
      "GET #{path} HTTP/1.1\r\n",
      "Host: 127.0.0.1:#{client.port}\r\n",
      "Connection: Upgrade\r\n",
      "Upgrade: websocket\r\n",
      "Sec-WebSocket-Version: 13\r\n",
      "Sec-WebSocket-Key: #{key}\r\n",
      headers(headers),
      "\r\n"
    ]

    :ok = :gen_tcp.send(client.socket, request)

    case recv_response(client.socket) do
      101 -> {:ok, client.ref}
      status when is_integer(status) -> {:error, status}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Upgrade and assert it succeeded, returning the stream ref."
  def connect!(client, path, headers \\ []) do
    {:ok, ref} = upgrade(client, path, headers)
    ref
  end

  def send_text(client, _ref, text), do: send_frame(client, 0x1, text)
  def send_binary(client, _ref, bin), do: send_frame(client, 0x2, bin)

  @doc "Await the next text frame and return its decoded JSON map."
  def recv_json(client, ref, timeout \\ 1000) do
    assert {:text, payload} = recv_frame(client, ref, timeout)
    Jason.decode!(payload)
  end

  @doc "Await the next binary frame and return its bytes."
  def recv_binary(client, ref, timeout \\ 1000) do
    assert {:binary, payload} = recv_frame(client, ref, timeout)
    payload
  end

  @doc "Await a close frame and return `{code, reason}`."
  def recv_close(client, ref, timeout \\ 1000) do
    case recv_close_frame(client, ref, timeout) do
      {:close, code, reason} ->
        {code, reason}

      :down ->
        flunk("socket closed before close frame for #{inspect(ref)}")

      {:error, :timeout} ->
        flunk("no close frame within #{timeout}ms for #{inspect(ref)}")

      other ->
        flunk("expected close frame for #{inspect(ref)}, got #{inspect(other)}")
    end
  end

  @doc """
  Await a hard server-side close, the kind Bandit's frame-size guard produces by
  stopping the connection process. The client sees this as either a clean close frame
  or a closed socket. Both mean "rejected and closed"; callers assert on
  `in [expected_code, :down]`.
  """
  def recv_close_or_down(client, ref, timeout \\ 5000) do
    case recv_close_frame(client, ref, timeout) do
      {:close, code, _reason} ->
        code

      :down ->
        :down

      {:error, :timeout} ->
        flunk("no close frame or socket close within #{timeout}ms for #{inspect(ref)}")

      other ->
        flunk("expected close frame or socket close for #{inspect(ref)}, got #{inspect(other)}")
    end
  end

  @doc "Assert no frame arrives within `timeout` ms on this connection."
  def refute_frame(client, ref, timeout \\ 200) do
    case recv_frame(client, ref, timeout) do
      {:error, :timeout} ->
        :ok

      :down ->
        :ok

      frame ->
        flunk("expected no frame within #{timeout}ms for #{inspect(ref)}, got #{inspect(frame)}")
    end
  end

  def close(%__MODULE__{socket: socket}), do: :gen_tcp.close(socket)

  defp headers(headers) do
    Enum.map(headers, fn {name, value} -> [to_string(name), ": ", to_string(value), "\r\n"] end)
  end

  defp recv_response(socket), do: recv_response(socket, "")

  defp recv_response(socket, acc) do
    if String.ends_with?(acc, "\r\n\r\n") do
      [status_line | header_lines] = String.split(acc, "\r\n", trim: true)
      "HTTP/1.1 " <> rest = status_line
      status = rest |> String.split(" ", parts: 2) |> hd() |> String.to_integer()
      drain_response_body(socket, header_lines)
      status
    else
      case :gen_tcp.recv(socket, 1, 5000) do
        {:ok, byte} -> recv_response(socket, acc <> byte)
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp drain_response_body(socket, header_lines) do
    len =
      Enum.find_value(header_lines, 0, fn line ->
        case String.split(line, ":", parts: 2) do
          [name, value] ->
            if String.downcase(name) == "content-length" do
              value |> String.trim() |> String.to_integer()
            end

          _ ->
            nil
        end
      end)

    if len > 0, do: :gen_tcp.recv(socket, len, 5000)
  end

  defp send_frame(%__MODULE__{socket: socket}, opcode, payload) do
    payload = IO.iodata_to_binary(payload)
    len = byte_size(payload)
    mask = :crypto.strong_rand_bytes(4)

    header =
      cond do
        len < 126 -> <<0x80 ||| opcode, 0x80 ||| len>>
        len < 65_536 -> <<0x80 ||| opcode, 0x80 ||| 126, len::16>>
        true -> <<0x80 ||| opcode, 0x80 ||| 127, len::64>>
      end

    :gen_tcp.send(socket, [header, mask, mask(payload, mask)])
  end

  defp recv_frame(client, ref, timeout) do
    case read_frame(client.socket, timeout) do
      {:ping, payload} ->
        send_frame(client, 0xA, payload)
        recv_frame(client, ref, timeout)

      :pong ->
        recv_frame(client, ref, timeout)

      other ->
        other
    end
  end

  defp recv_close_frame(client, ref, timeout) do
    case recv_frame(client, ref, timeout) do
      {:close, _code, _reason} = close -> close
      :down -> :down
      {:error, _reason} = error -> error
      _frame -> recv_close_frame(client, ref, timeout)
    end
  end

  defp read_frame(socket, timeout) do
    with {:ok, <<b1, b2>>} <- :gen_tcp.recv(socket, 2, timeout),
         {:ok, len} <- payload_len(socket, b2, timeout),
         {:ok, mask} <- maybe_mask(socket, b2, timeout),
         {:ok, payload} <- recv_payload(socket, len, timeout) do
      payload = if mask, do: mask(payload, mask), else: payload

      case b1 &&& 0x0F do
        0x1 -> {:text, payload}
        0x2 -> {:binary, payload}
        0x8 -> close_frame(payload)
        0x9 -> {:ping, payload}
        0xA -> :pong
        opcode -> {:error, {:unsupported_opcode, opcode}}
      end
    else
      {:error, :closed} -> :down
      {:error, reason} -> {:error, reason}
    end
  end

  defp payload_len(socket, b2, timeout) do
    case b2 &&& 0x7F do
      126 ->
        case :gen_tcp.recv(socket, 2, timeout) do
          {:ok, <<len::16>>} -> {:ok, len}
          other -> other
        end

      127 ->
        case :gen_tcp.recv(socket, 8, timeout) do
          {:ok, <<len::64>>} -> {:ok, len}
          other -> other
        end

      len ->
        {:ok, len}
    end
  end

  defp maybe_mask(socket, b2, timeout) do
    if (b2 &&& 0x80) == 0x80 do
      :gen_tcp.recv(socket, 4, timeout)
    else
      {:ok, nil}
    end
  end

  defp recv_payload(_socket, 0, _timeout), do: {:ok, ""}
  defp recv_payload(socket, len, timeout), do: :gen_tcp.recv(socket, len, timeout)

  defp close_frame(<<code::16, reason::binary>>), do: {:close, code, reason}
  defp close_frame(_), do: {:close, 1005, ""}

  defp mask("", _mask), do: ""

  defp mask(payload, mask) do
    stream =
      mask |> :binary.copy(div(byte_size(payload) + 3, 4)) |> binary_part(0, byte_size(payload))

    :crypto.exor(payload, stream)
  end
end
