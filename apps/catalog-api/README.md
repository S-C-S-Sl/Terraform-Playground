# catalog-api

ASP.NET-10-Minimal-API für Produkte. Veröffentlicht bei jeder Anlage oder Änderung ein
`ProductChanged`-Ereignis auf dem RabbitMQ-Topic-Exchange `catalog` (Routing-Key `product.changed`).
Andere Dienste werden nie direkt aufgerufen.

| Methode | Pfad | |
|---|---|---|
| GET | `/healthz` | Probe für Kubernetes, unabhängig von RabbitMQ |
| GET | `/api/catalog/products` | alle Produkte |
| GET | `/api/catalog/products/{id}` | ein Produkt |
| POST | `/api/catalog/products` | anlegen → `ProductChanged` |
| PUT | `/api/catalog/products/{id}` | ändern → `ProductChanged` |

Bewusste Vereinfachungen: Daten In-Memory (drei Beispielprodukte beim Start), Speichern und Senden
nicht atomar (produktiv: Outbox-Muster).

## Konfiguration

Abschnitt `RabbitMQ` in `appsettings.json`. Im Cluster kommen die Werte aus dem Secret
`rabbitmq-catalog-api` im Namespace des Produkts (`shop`), angelegt vom RabbitMQ-Chart:

| Umgebungsvariable | Schlüssel im Secret |
|---|---|
| `RabbitMQ__Host` | `host` (`rabbitmq.rabbitmq.svc.cluster.local`) |
| `RabbitMQ__Port` | `port` |
| `RabbitMQ__VirtualHost` | `vhost` (`shop`) |
| `RabbitMQ__Username` | `username` (`catalog-api`) |
| `RabbitMQ__Password` | `password` |

Die API startet auch ohne RabbitMQ; die Verbindung entsteht beim ersten Senden.

## Lokal ausführen (WSL oder Windows, .NET 10 SDK)

RabbitMQ aus dem Cluster per Port-Forwarding bereitstellen (eigenes Terminal):

```bash
kubectl -n rabbitmq port-forward svc/rabbitmq 5672:5672
```

Zugangsdaten setzen und starten:

```bash
cd apps/catalog-api
S=rabbitmq-catalog-api
export RabbitMQ__VirtualHost=$(kubectl -n shop get secret $S -o jsonpath='{.data.vhost}' | base64 -d)
export RabbitMQ__Username=$(kubectl -n shop get secret $S -o jsonpath='{.data.username}' | base64 -d)
export RabbitMQ__Password=$(kubectl -n shop get secret $S -o jsonpath='{.data.password}' | base64 -d)
dotnet run
```

Testen mit `catalog-api.http` oder:

```bash
curl -s http://localhost:5080/api/catalog/products
curl -s -X POST http://localhost:5080/api/catalog/products -H 'Content-Type: application/json' \
  -d '{"name":"Tasse XL","price":15.90,"stock":10}'
```

In der RabbitMQ-UI erscheinen danach der Exchange `catalog` und unter *Connections* die Verbindung
`catalog-api`. Noch gibt es keinen Empfänger: Ohne gebundene Queue verwirft RabbitMQ die Nachrichten.

## Image

```bash
docker build -t ghcr.io/sschabbach-mse/demo-catalog-api:0.1.0 apps/catalog-api
```
