namespace CatalogApi.Messaging;

/// <summary>Abschnitt "RabbitMQ" der Konfiguration (Umgebungsvariablen: RabbitMQ__Host usw.).</summary>
public sealed class RabbitMqOptions
{
    public const string Section = "RabbitMQ";

    public string Host { get; set; } = "localhost";
    public int Port { get; set; } = 5672;
    /// <summary>Virtueller Host des Produkts (z. B. "shop"); trennt Exchanges, Queues und Rechte.</summary>
    public string VirtualHost { get; set; } = "/";
    public string Username { get; set; } = "guest";
    public string Password { get; set; } = "guest";

    /// <summary>Topic-Exchange, auf dem der Katalog seine Ereignisse veröffentlicht.</summary>
    public string Exchange { get; set; } = "catalog";
}
