using System.Text.Json;
using Microsoft.Extensions.Options;
using RabbitMQ.Client;

namespace CatalogApi.Messaging;

/// <summary>
/// Veröffentlicht Ereignisse auf einem Topic-Exchange.
/// - Verbindung wird beim ersten Senden aufgebaut: Die API startet auch, wenn RabbitMQ (noch) nicht da ist.
/// - Publisher Confirms: BasicPublishAsync kehrt erst zurück, wenn der Broker die Nachricht bestätigt hat.
/// - Persistente Nachrichten auf einem dauerhaften Exchange (wirkt erst mit Persistenz im Broker).
/// </summary>
public sealed class RabbitMqPublisher(IOptions<RabbitMqOptions> options, ILogger<RabbitMqPublisher> logger)
    : IAsyncDisposable
{
    private readonly RabbitMqOptions _options = options.Value;
    private readonly SemaphoreSlim _lock = new(1, 1);
    private IConnection? _connection;
    private IChannel? _channel;

    public async Task PublishAsync<T>(string routingKey, T message, CancellationToken ct = default)
    {
        var body = JsonSerializer.SerializeToUtf8Bytes(message, JsonSerializerOptions.Web);
        var properties = new BasicProperties
        {
            ContentType = "application/json",
            DeliveryMode = DeliveryModes.Persistent,
            MessageId = Guid.NewGuid().ToString(),
            Type = typeof(T).Name,
            Timestamp = new AmqpTimestamp(DateTimeOffset.UtcNow.ToUnixTimeSeconds()),
        };

        // Ein Kanal wird nicht von mehreren Threads gleichzeitig zum Senden genutzt
        await _lock.WaitAsync(ct);
        try
        {
            var channel = await GetChannelAsync(ct);
            await channel.BasicPublishAsync(_options.Exchange, routingKey, mandatory: false,
                basicProperties: properties, body: body, cancellationToken: ct);
            logger.LogInformation("Veröffentlicht: {Type} -> {Exchange}/{RoutingKey}",
                properties.Type, _options.Exchange, routingKey);
        }
        finally
        {
            _lock.Release();
        }
    }

    private async Task<IChannel> GetChannelAsync(CancellationToken ct)
    {
        if (_channel is { IsOpen: true }) return _channel;

        var factory = new ConnectionFactory
        {
            HostName = _options.Host,
            Port = _options.Port,
            VirtualHost = _options.VirtualHost,
            UserName = _options.Username,
            Password = _options.Password,
            ClientProvidedName = "catalog-api", // erscheint in der Management-UI unter Connections
        };

        _connection ??= await factory.CreateConnectionAsync(ct);
        _channel = await _connection.CreateChannelAsync(
            new CreateChannelOptions(publisherConfirmationsEnabled: true, publisherConfirmationTrackingEnabled: true),
            ct);

        await _channel.ExchangeDeclareAsync(_options.Exchange, ExchangeType.Topic, durable: true,
            cancellationToken: ct);
        logger.LogInformation("Mit RabbitMQ verbunden: {Host}:{Port}, vhost {VirtualHost}, Exchange {Exchange}",
            _options.Host, _options.Port, _options.VirtualHost, _options.Exchange);
        return _channel;
    }

    public async ValueTask DisposeAsync()
    {
        if (_channel is not null) await _channel.DisposeAsync();
        if (_connection is not null) await _connection.DisposeAsync();
        _lock.Dispose();
    }
}
