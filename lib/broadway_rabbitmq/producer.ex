defmodule BroadwayRabbitmq.Producer do
  @moduledoc """
  A RabbitMQ producer for Broadway.

  ## Features

    * Automatically acknowledges/rejects messages.
    * Handles connection outages using backoff for retries.

  ## Options

    * `:queue` - Required. The name of the queue.
    * `:connection` - Optional. Defines a set of options used by the RabbitMQ
      client to open the connection with the RabbitMQ broker. See
      `AMQP.Connection.open/1` for the full list of options.
    * `:declare` - Optional. Defines a set of options used by the RabbitMQ
      client to declare the queue. See `AMQP.Queue.declare/3` for the full list of
      options.
    * `:qos` - Optional. Defines a set of prefetch options used by the RabbitMQ client.
      See `AMQP.Basic.qos/2` for the full list of options. Pay attention that the
      `:global` option is not supported by Broadway since each producer holds only one
      channel per connection.
    * `:backoff_min` - The minimum backoff interval (default: `1_000`)
    * `:backoff_max` - The maximum backoff interval (default: `30_000`)
    * `:backoff_type` - The backoff strategy, `:stop` for no backoff and
    to stop, `:exp` for exponential, `:rand` for random and `:rand_exp` for
    random exponential (default: `:rand_exp`)

  ## Example

      Broadway.start_link(MyBroadway,
        name: MyBroadway,
        producers: [
          default: [
            module:
              {BroadwayRabbitmq.Producer,
              queue: "my_queue",
              connection: [
                username: "user",
                password: "password",
                host: "192.168.0.10"
              ],
              declare: [
                durable: true,
                arguments: [
                  {"x-dead-letter-exchange", :longstr, ""},
                  {"x-dead-letter-routing-key", :longstr, "my_queue_error"}
                ]
              ]
              qos: [
                prefetch_count: 50
              ]},
            stages: 5
          ]
        ],
        processors: [
          default: []
        ]
      )

  ## Back-pressure and `:prefetch_count`

  Unlike the RabittMQ client that has a default `:prefetch_count` = 0,
  which disables back-pressure, BroadwayRabbitMQ overwrite the default
  value to `50` enabling the back-pressure mechanism. You can still define
  it as `0`, however, if you do this, make sure the machine has enough
  resources to handle the number of messages coming from the broker.

  This is important because the BroadwayRabbitMQ producer does not work
  as a poller like BroadwaySQS. Instead, it maintains an active connection
  with a subscribed consumer that receives messages continuously as they
  arrive in the queue. This is more efficient than using the `basic.get`
  method, however, it removes the ability of the GenStage producer to control
  the demand. Therefore we need to use the `:prefetch_count` option to
  impose back-pressure at the channel level.

  ## Connection loss and backoff

  In case the connection cannot be opened or if a stablished connection is lost,
  the producer will try to reconnect using an exponential random backoff strategy.
  The strategy can be configured using the `:backoff_type` option.

  ## Unsupported options

  Currently, Broadway does not accept options for `Basic.consume/4` which
  is called internally by the producer with default values. That means options
  like `:no_ack` are not supported. If you have a scenario where you need to
  customize those options, please open an issue, so we can consider adding this
  feature.
  """

  use GenStage

  require Logger

  alias Broadway.{Message, Acknowledger, Producer}
  alias BroadwayRabbitmq.Backoff

  @behaviour Acknowledger
  @behaviour Producer

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    client = opts[:client] || BroadwayRabbitmq.AmqpClient

    case client.init(opts) do
      {:error, message} ->
        raise ArgumentError, "invalid options given to #{inspect(client)}.init/1, " <> message

      {:ok, queue_name, config} ->
        send(self(), :connect)

        prefetch_count = config[:qos][:prefetch_count]
        options = [buffer_size: prefetch_count * 5]

        {:producer,
         %{
           client: client,
           channel: nil,
           consumer_tag: nil,
           queue_name: queue_name,
           config: config,
           backoff: Backoff.new(opts),
           conn_ref: nil
         }, options}
    end
  end

  @impl true
  def handle_demand(_incoming_demand, state) do
    {:noreply, [], state}
  end

  @impl true
  def handle_info({:basic_consume_ok, %{consumer_tag: tag}}, state) do
    {:noreply, [], %{state | consumer_tag: tag}}
  end

  def handle_info({:basic_cancel, _}, state) do
    # TODO: Better treat this differently
    {:stop, :normal, %{state | consumer_tag: nil}}
  end

  def handle_info({:basic_cancel_ok, _}, state) do
    {:noreply, [], %{state | consumer_tag: nil}}
  end

  def handle_info({:basic_deliver, payload, meta}, state) do
    %{channel: channel, client: client} = state
    %{delivery_tag: tag} = meta

    ack_data = %{
      delivery_tag: tag,
      client: client
    }

    message = %Message{data: payload, acknowledger: {__MODULE__, channel, ack_data}}

    {:noreply, [message], state}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{conn_ref: ref} = state) do
    {:noreply, [], connect(state)}
  end

  def handle_info(:connect, state) do
    {:noreply, [], connect(state)}
  end

  def handle_info(_, state) do
    {:noreply, [], state}
  end

  @impl true
  def terminate(_reason, state) do
    %{client: client, channel: channel} = state

    if channel do
      client.close_connection(channel.conn)
    end

    :ok
  end

  @impl Acknowledger
  def ack(channel, successful, failed) do
    ack_messages(successful, channel, :ack)
    ack_messages(failed, channel, :reject)
  end

  @impl Producer
  def prepare_for_draining(%{channel: nil}) do
    :ok
  end

  def prepare_for_draining(state) do
    %{client: client, channel: channel, consumer_tag: consumer_tag} = state

    case client.cancel(channel, consumer_tag) do
      {:ok, ^consumer_tag} ->
        :ok

      {:error, error} ->
        Logger.error("Could not cancel producer while draining. Channel is #{error}")
        :ok
    end
  end

  defp ack_messages(messages, channel, ack_func) do
    Enum.each(messages, fn msg ->
      {client, delivery_tag} = extract_client_and_delivery_tag(msg)

      try do
        apply(client, ack_func, [channel, delivery_tag])
      catch
        kind, reason ->
          Logger.error(Exception.format(kind, reason, System.stacktrace()))
      end
    end)
  end

  defp extract_client_and_delivery_tag(message) do
    {_, _, %{client: client, delivery_tag: delivery_tag}} = message.acknowledger
    {client, delivery_tag}
  end

  defp connect(state) do
    %{client: client, queue_name: queue_name, config: config, backoff: backoff} = state
    # TODO: Treat other setup errors properly
    case client.setup_channel(queue_name, config) do
      {:ok, channel} ->
        ref = Process.monitor(channel.conn.pid)
        backoff = backoff && Backoff.reset(backoff)
        consumer_tag = client.consume(channel, queue_name)
        %{state | channel: channel, consumer_tag: consumer_tag, backoff: backoff, conn_ref: ref}

      {:error, :econnrefused} ->
        handle_backoff(state)
    end
  end

  defp handle_backoff(%{backoff: backoff} = state) do
    Logger.error("Cannot connect to RabbitMQ broker")

    new_backoff =
      if backoff do
        {timeout, backoff} = Backoff.backoff(backoff)
        Process.send_after(self(), :connect, timeout)
        backoff
      end

    %{state | channel: nil, consumer_tag: nil, backoff: new_backoff, conn_ref: nil}
  end
end
