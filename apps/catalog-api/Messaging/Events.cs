namespace CatalogApi.Messaging;

/// <summary>
/// Wird bei jeder Anlage oder Änderung eines Produkts veröffentlicht.
/// Empfänger (z. B. orders-api) führen damit eine eigene Kopie der Daten, die sie brauchen.
/// </summary>
public sealed record ProductChanged(Guid ProductId, string Name, decimal Price, DateTimeOffset OccurredAt);
