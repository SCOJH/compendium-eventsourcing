// -----------------------------------------------------------------------
// <copyright file="PostgreSqlEventStoreLogicalNameTests.cs" company="Sassy Solutions">
//     Copyright (c) 2026 Sassy Solutions. Licensed under the MIT License.
//     See LICENSE in the project root for license information.
// </copyright>
// -----------------------------------------------------------------------

using Compendium.Adapters.PostgreSQL.Configuration;
using Compendium.Adapters.PostgreSQL.DependencyInjection;
using Compendium.Adapters.PostgreSQL.EventStore;
using Compendium.Core.Domain.Events;
using Compendium.Core.EventSourcing;
using Compendium.Core.EventSourcing.Attributes;
using AwesomeAssertions;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;
using NSubstitute;

namespace Compendium.Adapters.PostgreSQL.Tests.EventStore;

/// <summary>
/// Unit tests for the name <see cref="PostgreSqlEventStore"/> writes in the <c>event_type</c> column.
/// The store asks the <see cref="IEventTypeRegistry"/> port for the logical name of an event; without
/// a registry it keeps writing the assembly qualified name, as it always did. The round trip through
/// a real PostgreSQL, for each of the three append strategies, lives in the integration suite.
/// </summary>
public class PostgreSqlEventStoreLogicalNameTests
{
    private const string ValidConnectionString = "Host=localhost;Username=u;Password=p;Database=d";
    private const string LogicalName = "Tests.OrderPlaced";

    private static PostgreSqlEventStore CreateStore(
        IEventTypeRegistry? registry,
        ILogger<PostgreSqlEventStore>? logger = null)
    {
        var options = Options.Create(new PostgreSqlOptions { ConnectionString = ValidConnectionString });

        return new PostgreSqlEventStore(
            options,
            Substitute.For<IEventDeserializer>(),
            logger ?? Substitute.For<ILogger<PostgreSqlEventStore>>(),
            tenantContext: null,
            metrics: null,
            eventTypeRegistry: registry);
    }

    [Fact]
    public void ResolveEventTypeName_WithRegistry_AndDecoratedEvent_ReturnsTheLogicalName()
    {
        // Arrange
        using var registry = new EventTypeRegistry();
        var store = CreateStore(registry);

        // Act
        var name = store.ResolveEventTypeName(typeof(DecoratedEvent));

        // Assert
        name.Should().Be(LogicalName);
        name.Should().NotBe(typeof(DecoratedEvent).AssemblyQualifiedName);
    }

    [Fact]
    public void ResolveEventTypeName_WithRegistry_AndUndecoratedEvent_KeepsTheAssemblyQualifiedName()
    {
        // Arrange
        using var registry = new EventTypeRegistry();
        var store = CreateStore(registry);

        // Act
        var name = store.ResolveEventTypeName(typeof(UndecoratedEvent));

        // Assert — a consumer that adopts no attribute sees no difference in what is written.
        name.Should().Be(typeof(UndecoratedEvent).AssemblyQualifiedName);
    }

    [Fact]
    public void ResolveEventTypeName_WithoutRegistry_WritesTheAssemblyQualifiedName_EvenForADecoratedEvent()
    {
        // Arrange — a store built by hand without a registry behaves exactly as before logical names.
        var store = CreateStore(registry: null);

        // Act
        var name = store.ResolveEventTypeName(typeof(DecoratedEvent));

        // Assert
        name.Should().Be(typeof(DecoratedEvent).AssemblyQualifiedName);
    }

    [Fact]
    public void ResolveEventTypeName_AsksThePort_RatherThanReadingTheAttributeItself()
    {
        // Arrange — the registry is the single authority on a type's name; the adapter must not
        // hold a second truth (reflection on the attribute) that could drift from it.
        var registry = Substitute.For<IEventTypeRegistry>();
        registry.GetLogicalName(typeof(DecoratedEvent)).Returns("Named.By.The.Port");
        var store = CreateStore(registry);

        // Act
        var name = store.ResolveEventTypeName(typeof(DecoratedEvent));

        // Assert
        name.Should().Be("Named.By.The.Port");
        registry.Received(1).GetLogicalName(typeof(DecoratedEvent));
    }

    [Fact]
    public void Ctor_WithoutRegistry_WarnsThatNamesFallBackToTheAssemblyQualifiedName()
    {
        // Arrange
        var logger = Substitute.For<ILogger<PostgreSqlEventStore>>();

        // Act
        _ = CreateStore(registry: null, logger);

        // Assert — the fallback is legitimate but must not be silent.
        WarningCount(logger).Should().Be(1);
    }

    [Fact]
    public void Ctor_WithRegistry_DoesNotWarn()
    {
        // Arrange
        var logger = Substitute.For<ILogger<PostgreSqlEventStore>>();
        using var registry = new EventTypeRegistry();

        // Act
        _ = CreateStore(registry, logger);

        // Assert
        WarningCount(logger).Should().Be(0);
    }

    [Fact]
    public async Task AddPostgreSqlEventStore_InjectsTheRegistry_SoTheResolvedStoreWritesLogicalNames()
    {
        // Arrange — the supported wiring path must reach the logical name without any extra call.
        var services = new ServiceCollection();
        services.AddLogging();
        services.AddPostgreSqlEventStore(ValidConnectionString);
        await using var provider = services.BuildServiceProvider();

        // Act
        var store = provider.GetRequiredService<PostgreSqlEventStore>();
        var name = store.ResolveEventTypeName(typeof(DecoratedEvent));

        // Assert
        name.Should().Be(LogicalName);
    }

    private static int WarningCount(ILogger logger) =>
        logger.ReceivedCalls().Count(call =>
            call.GetMethodInfo().Name == nameof(ILogger.Log) &&
            call.GetArguments()[0] is LogLevel.Warning);

    [EventTypeName(LogicalName)]
    private sealed class DecoratedEvent : IDomainEvent
    {
        public Guid EventId { get; init; }
        public string AggregateId { get; init; } = string.Empty;
        public string AggregateType { get; init; } = string.Empty;
        public DateTimeOffset OccurredOn { get; init; }
        public long AggregateVersion { get; init; }
        public int EventVersion { get; init; } = 1;
    }

    private sealed class UndecoratedEvent : IDomainEvent
    {
        public Guid EventId { get; init; }
        public string AggregateId { get; init; } = string.Empty;
        public string AggregateType { get; init; } = string.Empty;
        public DateTimeOffset OccurredOn { get; init; }
        public long AggregateVersion { get; init; }
        public int EventVersion { get; init; } = 1;
    }
}
